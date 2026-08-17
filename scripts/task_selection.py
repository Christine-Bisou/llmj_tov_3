import re
import json
import ast
import random
import pandas as pd
from collections import Counter


# =========================================================
# БАЗОВЫЕ ПАРАМЕТРЫ ОТБОРА
#
# Отбор идет только по двум осям:
# - баланс по моделям (семейства, stage, разнообразие, wins/losses/draws)
# - баланс по пулам
#
# Баланса по воркерам нет.
# Задачи со skip не участвуют в отборе вообще.
# =========================================================

DEFAULT_SELECTED_TASKS = 20

# Баланс по семействам моделей
TARGET_BUCKET_SHARES = {
    "Alice": 0.40,
    "Neuro": 0.20,
    "VLM": 0.20,
    "Competitors": 0.20,
}

# Пулы:
# - мягкий штраф после 2
# - жесткий фильтр после 8 только если он не мешает добрать целевое число задач
POOL_SOFT_LIMIT = 2
POOL_HARD_LIMIT = 8

# Максимум специальных задач
MAX_BOTH_BAD_TASKS = 1

CORE_BUCKETS = ("Alice", "Neuro", "VLM", "Competitors")
STAGE_FAMILIES = ("Neuro", "VLM")
STAGES = ("learn", "validate")



# =========================================================
# БАЗОВЫЕ ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
# =========================================================

def _is_nullish(x):
    return x is None or (isinstance(x, float) and pd.isna(x))


def _to_str(x):
    return "" if _is_nullish(x) else str(x).strip()


def _maybe_parse_obj(x):
    if isinstance(x, (dict, list)):
        return x

    if _is_nullish(x):
        return {}

    if isinstance(x, str):
        s = x.strip()
        if not s:
            return {}

        for parser in (json.loads, ast.literal_eval):
            try:
                v = parser(s)
                if isinstance(v, (dict, list)):
                    return v
            except Exception:
                pass

    return {}


def _as_dict(x):
    v = _maybe_parse_obj(x)
    return v if isinstance(v, dict) else {}


def _as_list(x):
    v = _maybe_parse_obj(x)
    return v if isinstance(v, list) else []


def _clean_value(x):
    try:
        if pd.isna(x):
            return None
    except Exception:
        pass
    return x


def _resolve_total_target(param1):
    if param1 is None:
        return DEFAULT_SELECTED_TASKS
    try:
        return max(int(param1), 0)
    except Exception:
        return DEFAULT_SELECTED_TASKS


# =========================================================
# СЕМЕЙСТВА МОДЕЛЕЙ И БАКЕТЫ
# =========================================================

def _family_from_model_name(name):
    t = str(name or "").strip().lower()

    if t.startswith("sft_rewrite"):
        return "Neuro"

    if (
        t.startswith("tov_v1")
        or t.startswith("tov_v3")
        or t.startswith("bundle9")
        or t.startswith("merge_grpo")
        or t.startswith("of_course")
        or t.startswith("sampled_proactivity_tov_v3")
        or t.startswith("ng7h_32b_pv4_v2bin_lv6_fixed_t_dv7e0_rsselfbleu01x2")
        or t.startswith("sft_alice_add_proactive.add_preprocessing.retrain.32b_202512")
    ):
        return "Alice"

    if t == "59306fff9d214aaa6069e48e6a4d7a43449d4e6f414d3b9f4727261905f7ba9f":
        return "Qwen"

    if (
        re.search(r"(neuro_with_promt|neuro_with_prompt|mandarin|neuro_)", t)
        or re.search(r"(^|[^a-z0-9_])neuro([^a-z0-9_]|$)", t)
        or t.startswith("nap_")
        or t.startswith("grpo_tov_sbs_v1_formula_2")
        or t.startswith("tov_sft")
    ):
        return "Neuro"

    if re.search(r"v7", t):
        return "VLM"

    if re.search(r"gpt", t):
        return "GPT"
    if re.search(r"gemini", t):
        return "Gemini"
    if re.search(r"deepse", t):
        return "Deepseek"
    if re.search(r"qwen", t):
        return "Qwen"
    if re.search(r"claude", t):
        return "Claude"
    if re.search(r"kimi", t):
        return "Kimi"
    if re.search(r"smth", t):
        return "Smth"

    if re.search(r"10h|235b|h7|h10|prod|rc_", t):
        return "Alice"

    return "Other"


def _family_bucket(family_name):
    family = str(family_name or "").strip()
    if family in {"Alice", "Neuro", "VLM"}:
        return family
    return "Competitors"


# =========================================================
# ЧТЕНИЕ ПОЛЕЙ ИЗ INPUTVALUES / OUTPUTVALUES
#
# ВАЖНО:
# - source_A / source_B берем только из inputValues.answers
# - priority_type берем только из inputValues.metadata.priority_type
# - winner берем только из outputValues.winner
# - outputValues.skip читаем только для того, чтобы выкинуть такие строки
# =========================================================

def _extract_sources_from_input_values(input_values):
    iv = _as_dict(input_values)
    answers = _as_list(iv.get("answers"))

    source_a = ""
    source_b = ""

    for ans in answers:
        ans = _as_dict(ans)
        label = _to_str(ans.get("label")).upper()
        source = _to_str(ans.get("source"))

        if label == "A" and not source_a:
            source_a = source
        elif label == "B" and not source_b:
            source_b = source

    return source_a, source_b


def _extract_priority_type(input_values):
    iv = _as_dict(input_values)
    metadata = _as_dict(iv.get("metadata"))
    value = _to_str(metadata.get("priority_type")).lower()

    if value in STAGES:
        return value
    return None


def _is_skipped(output_values):
    ov = _as_dict(output_values)
    skip_value = ov.get("skip")

    if isinstance(skip_value, bool):
        return skip_value

    if isinstance(skip_value, str):
        return skip_value.strip().lower() == "true"

    return bool(skip_value)


def _extract_raw_winner(output_values):
    ov = _as_dict(output_values)
    winner = _to_str(ov.get("winner")).lower()

    if winner in {"answer_a", "answer_b", "draw", "both_bad"}:
        return winner

    return None


def _extract_worker_verdict(input_values, output_values):
    # Строки со skip не дают вердикта и дальше не идут
    if _is_skipped(output_values):
        return None

    raw_winner = _extract_raw_winner(output_values)
    source_a, source_b = _extract_sources_from_input_values(input_values)

    if raw_winner == "answer_a":
        return source_a or None
    if raw_winner == "answer_b":
        return source_b or None
    if raw_winner == "draw":
        return "draw"
    if raw_winner == "both_bad":
        return "both_bad"

    return None


# =========================================================
# ПОДГОТОВКА СЫРЫХ СТРОК ИЗ IN1
# =========================================================

def _prepare_tasks_base_df(df):
    required_cols = ["poolId", "taskId", "workerId", "inputValues", "outputValues", "status"]
    missing = [c for c in required_cols if c not in df.columns]
    if missing:
        raise ValueError(f"В in1 нет обязательных колонок: {missing}")

    out = df.copy()
    out = out[out["status"].apply(lambda x: _to_str(x).upper()) == "ACCEPTED"].copy()

    source_pairs = out["inputValues"].apply(_extract_sources_from_input_values)
    out["source_A"] = [pair[0] for pair in source_pairs]
    out["source_B"] = [pair[1] for pair in source_pairs]

    out["priority_type"] = out["inputValues"].apply(_extract_priority_type)
    out["raw_winner"] = out["outputValues"].apply(_extract_raw_winner)

    out["worker_verdict"] = out.apply(
        lambda r: _extract_worker_verdict(r["inputValues"], r["outputValues"]),
        axis=1,
    )

    out["poolId"] = out["poolId"].astype(str)
    out["taskId"] = out["taskId"].astype(str)
    out["workerId"] = out["workerId"].astype(str)
    out["source_A"] = out["source_A"].fillna("").astype(str)
    out["source_B"] = out["source_B"].fillna("").astype(str)

    out = out[
        (out["poolId"] != "")
        & (out["taskId"] != "")
        & (out["workerId"] != "")
        & (out["source_A"] != "")
        & (out["source_B"] != "")
        & (out["worker_verdict"].notna())
    ].copy()

    out["source_A_family"] = out["source_A"].apply(_family_from_model_name)
    out["source_B_family"] = out["source_B"].apply(_family_from_model_name)
    out["row_key"] = out["poolId"].astype(str) + "||" + out["taskId"].astype(str)
    out["_raw_output_order"] = range(len(out))

    return out.reset_index(drop=True)


def _normalize_tasks_input(df):
    base_df = _prepare_tasks_base_df(df)

    out = base_df[
        [
            "poolId",
            "taskId",
            "workerId",
            "source_A",
            "source_B",
            "source_A_family",
            "source_B_family",
            "priority_type",
            "worker_verdict",
            "row_key",
        ]
    ].copy()

    out = out.rename(columns={"workerId": "worker_id"})
    return out.reset_index(drop=True)


# =========================================================
# НОРМАЛИЗАЦИЯ IN2
# IN2 - базовая статистика по моделям
# =========================================================

def _normalize_model_balance_input(df):
    required_cols = ["model", "wins", "losses", "draws", "total", "learn", "validate"]
    missing = [c for c in required_cols if c not in df.columns]
    if missing:
        raise ValueError(f"В in2 нет обязательных колонок: {missing}")

    out = df.copy()

    out["model"] = out["model"].fillna("").astype(str)
    out["wins"] = pd.to_numeric(out["wins"], errors="coerce").fillna(0).astype(int)
    out["losses"] = pd.to_numeric(out["losses"], errors="coerce").fillna(0).astype(int)
    out["draws"] = pd.to_numeric(out["draws"], errors="coerce").fillna(0).astype(int)
    out["total"] = pd.to_numeric(out["total"], errors="coerce").fillna(0).astype(int)
    out["learn"] = pd.to_numeric(out["learn"], errors="coerce").fillna(0).astype(int)
    out["validate"] = pd.to_numeric(out["validate"], errors="coerce").fillna(0).astype(int)

    if "both_bad" in out.columns:
        out["both_bad"] = pd.to_numeric(out["both_bad"], errors="coerce").fillna(0).astype(int)
    else:
        out["both_bad"] = 0

    out = out[out["model"] != ""].copy()
    if out.empty:
        return pd.DataFrame(columns=["model", "wins", "losses", "draws", "both_bad", "learn", "validate", "total"])

    out = (
        out.groupby("model", sort=False)[["wins", "losses", "draws", "both_bad", "learn", "validate", "total"]]
        .sum()
        .reset_index()
    )

    return out


# =========================================================
# БАЗОВЫЕ СЧЕТЧИКИ ИЗ IN2
# - bucket counts идут из total
# - stage counts идут из learn / validate
# =========================================================

def _build_base_bucket_counts(model_df):
    counts = Counter()

    for _, r in model_df.iterrows():
        model_name = str(r["model"])
        total = int(r["total"])
        family = _family_from_model_name(model_name)
        bucket = _family_bucket(family)
        counts[bucket] += total

    return counts


def _build_base_stage_counts(model_df):
    counts = Counter()

    for _, r in model_df.iterrows():
        model_name = str(r["model"])
        family = _family_from_model_name(model_name)

        if family not in STAGE_FAMILIES:
            continue

        counts[(family, "learn")] += int(r["learn"])
        counts[(family, "validate")] += int(r["validate"])

    return counts


# =========================================================
# АГРЕГАЦИЯ ВЕРДИКТА ПО ЗАДАЧЕ
#
# aggregated_verdict хранится как:
# - имя source
# - draw
# - both_bad
# =========================================================

def _aggregate_verdict(votes):
    votes = [v for v in votes if v is not None]
    n = len(votes)
    if n == 0:
        return None

    counts = Counter(votes)
    draw_cnt = int(counts.get("draw", 0))
    both_bad_cnt = int(counts.get("both_bad", 0))

    source_counts = {
        k: int(v)
        for k, v in counts.items()
        if k not in {"draw", "both_bad"}
    }

    if n == 1:
        return votes[0]

    if n == 2:
        if len(counts) == 1:
            return votes[0]

        if len(source_counts) >= 2:
            return "draw"

        if len(source_counts) == 1 and (draw_cnt > 0 or both_bad_cnt > 0):
            return next(iter(source_counts.keys()))

        if draw_cnt > 0 and both_bad_cnt > 0:
            return "both_bad"

        return None

    for verdict_value, cnt in counts.items():
        if 2 * cnt > n:
            return verdict_value

    if both_bad_cnt > 0:
        return "both_bad"
    if draw_cnt > 0:
        return "draw"
    if len(source_counts) > 1:
        return "draw"
    if len(source_counts) == 1:
        return next(iter(source_counts.keys()))

    return None


# =========================================================
# СТАТИСТИКА ПО МОДЕЛЯМ
# В score используются:
# - total для diversity
# - wins / losses / draws для outcome-баланса
# =========================================================

def _zero_model_outcome_stats():
    return {
        "wins": 0,
        "losses": 0,
        "draws": 0,
        "both_bad": 0,
        "learn": 0,
        "validate": 0,
        "total": 0,
    }


def _build_model_stats(model_df):
    return {
        str(r["model"]): {
            "wins": int(r["wins"]),
            "losses": int(r["losses"]),
            "draws": int(r["draws"]),
            "both_bad": int(r["both_bad"]),
            "learn": int(r["learn"]),
            "validate": int(r["validate"]),
            "total": int(r["total"]),
        }
        for _, r in model_df.iterrows()
    }


def _model_stat(model_stats, model_name):
    return model_stats.get(str(model_name), _zero_model_outcome_stats().copy())


def _copy_model_outcomes(model_outcomes):
    return {name: stats.copy() for name, stats in model_outcomes.items()}


def _ensure_sources_in_model_outcomes(model_outcomes, tasks_df):
    all_sources = set(tasks_df["source_A"].astype(str)) | set(tasks_df["source_B"].astype(str))
    for source_name in all_sources:
        model_outcomes.setdefault(str(source_name), _zero_model_outcome_stats().copy())
    return model_outcomes


def _task_outcome_effect(row):
    effect = {}

    def add(source_name, wins=0, losses=0, draws=0, total=0):
        source_name = str(source_name)
        if source_name not in effect:
            effect[source_name] = _zero_model_outcome_stats().copy()

        effect[source_name]["wins"] += int(wins)
        effect[source_name]["losses"] += int(losses)
        effect[source_name]["draws"] += int(draws)
        effect[source_name]["total"] += int(total)

    source_1 = str(row["source_1"])
    source_2 = str(row["source_2"])
    verdict = row["aggregated_verdict"]

    if verdict == source_1:
        add(source_1, wins=1, total=1)
        add(source_2, losses=1, total=1)
    elif verdict == source_2:
        add(source_2, wins=1, total=1)
        add(source_1, losses=1, total=1)
    elif verdict == "draw":
        add(source_1, draws=1, total=1)
        add(source_2, draws=1, total=1)

    return effect


def _apply_outcome_effect(model_outcomes, effect):
    for source_name, delta in effect.items():
        model_outcomes.setdefault(str(source_name), _zero_model_outcome_stats().copy())
        for key, value in delta.items():
            model_outcomes[source_name][key] = int(model_outcomes[source_name].get(key, 0)) + int(value)


def _outcome_missing_count(stats):
    return sum(
        1 for key in ("wins", "losses", "draws")
        if int(stats.get(key, 0)) == 0
    )


def _outcome_spread(stats):
    values = [
        int(stats.get("wins", 0)),
        int(stats.get("losses", 0)),
        int(stats.get("draws", 0)),
    ]
    return max(values) - min(values)


# =========================================================
# ПОСТРОЕНИЕ КАТАЛОГА ЗАДАЧ
#
# Здесь схлопываем сырые worker-строки в одну задачу.
# Группировка идет по poolId + taskId.
# =========================================================

def _majority_priority_type(values):
    vals = [str(v) for v in values if v in STAGES]
    if not vals:
        return None
    return Counter(vals).most_common(1)[0][0]


def _build_tasks_catalog(tasks_df):
    rows = []

    grouped = tasks_df.groupby(["row_key", "poolId", "taskId"], sort=False)

    for (_, pool_id, task_id), g in grouped:
        # Перекрытие не требуется: задача годится с любым числом редакторов,
        # в том числе с одним
        worker_ids = sorted(set(g["worker_id"].astype(str).tolist()))
        worker_cnt = len(worker_ids)

        all_sources = sorted(
            set(g["source_A"].astype(str).tolist()) | set(g["source_B"].astype(str).tolist())
        )
        if len(all_sources) != 2:
            continue

        source_1, source_2 = all_sources
        source_1_family = _family_from_model_name(source_1)
        source_2_family = _family_from_model_name(source_2)

        aggregated_verdict = _aggregate_verdict(g["worker_verdict"].tolist())
        if aggregated_verdict is None:
            continue

        priority_type = _majority_priority_type(g["priority_type"].tolist())

        aggregated_winner_family = None
        if aggregated_verdict == source_1:
            aggregated_winner_family = source_1_family
        elif aggregated_verdict == source_2:
            aggregated_winner_family = source_2_family

        rows.append({
            "row_key": str(g["row_key"].iloc[0]),
            "poolId": str(pool_id),
            "taskId": str(task_id),
            "worker_ids": worker_ids,
            "worker_cnt": worker_cnt,
            "source_1": source_1,
            "source_2": source_2,
            "source_1_family": source_1_family,
            "source_2_family": source_2_family,
            "source_1_bucket": _family_bucket(source_1_family),
            "source_2_bucket": _family_bucket(source_2_family),
            "priority_type": priority_type,
            "aggregated_verdict": aggregated_verdict,
            "aggregated_winner_family": aggregated_winner_family,
        })

    if not rows:
        return pd.DataFrame()

    return pd.DataFrame(rows).reset_index(drop=True)


# =========================================================
# ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ ПО ЗАДАЧЕ
# =========================================================

def _task_sources(row):
    return [str(row["source_1"]), str(row["source_2"])]


def _task_source_pair_key(row):
    return tuple(sorted(_task_sources(row)))


def _task_buckets(row):
    return [str(row["source_1_bucket"]), str(row["source_2_bucket"])]


def _task_stage_slots(row):
    slots = []
    priority_type = row["priority_type"]

    if priority_type not in STAGES:
        return slots

    family_1 = str(row["source_1_family"])
    family_2 = str(row["source_2_family"])

    if family_1 in STAGE_FAMILIES:
        slots.append((family_1, str(priority_type)))

    if family_2 in STAGE_FAMILIES:
        slots.append((family_2, str(priority_type)))

    return slots


# =========================================================
# МЕТРИКИ БАЛАНСА ПО СЕМЕЙСТВАМ
# Считаем от базы in2 + текущий добор
# =========================================================

def _bucket_balance_distance(bucket_counts, total_slots):
    if total_slots <= 0:
        return 0.0

    return sum(
        abs(float(bucket_counts[bucket]) - TARGET_BUCKET_SHARES[bucket] * total_slots)
        for bucket in CORE_BUCKETS
    )


# =========================================================
# SCORE ПО СЕМЕЙСТВАМ
# Держим Alice / Neuro / VLM / Competitors в нужных долях
# Считаем от базы in2 + текущий добор
# =========================================================

def _family_balance_score(row, current_bucket_counts):
    before_total = sum(int(v) for v in current_bucket_counts.values())
    before_distance = _bucket_balance_distance(current_bucket_counts, before_total)

    after_counts = Counter(current_bucket_counts)
    for bucket in _task_buckets(row):
        after_counts[bucket] += 1

    after_total = before_total + 2
    after_distance = _bucket_balance_distance(after_counts, after_total)
    improvement = before_distance - after_distance

    bucket_1 = str(row["source_1_bucket"])
    bucket_2 = str(row["source_2_bucket"])
    cross_bucket_rank = 0 if bucket_1 != bucket_2 else 1
    bucket_peak_after = max(int(after_counts[bucket_1]), int(after_counts[bucket_2]))

    return (
        after_distance,
        -improvement,
        cross_bucket_rank,
        bucket_peak_after,
    )


# =========================================================
# SCORE ПО STAGE
# Считаем от базы in2 + текущий добор
# Источник stage для задач: inputValues.metadata.priority_type
# =========================================================

def _stage_balance_score(row, current_stage_counts):
    row_stage_slots = _task_stage_slots(row)
    after_counts = Counter(current_stage_counts)

    for slot in row_stage_slots:
        after_counts[slot] += 1

    introduced_missing_stage = 0
    for slot in set(row_stage_slots):
        if int(current_stage_counts[slot]) == 0:
            introduced_missing_stage += 1

    missing_stage_families = 0
    imbalance_sum = 0.0

    for family in STAGE_FAMILIES:
        learn_cnt = int(after_counts[(family, "learn")])
        validate_cnt = int(after_counts[(family, "validate")])
        total = learn_cnt + validate_cnt

        if total == 0:
            continue

        if learn_cnt == 0 or validate_cnt == 0:
            missing_stage_families += 1

        imbalance_sum += abs(learn_cnt - validate_cnt) / total

    no_stage_row = 0 if row_stage_slots else 1

    return (
        missing_stage_families,
        imbalance_sum,
        -introduced_missing_stage,
        no_stage_row,
    )


# =========================================================
# SCORE ПО SOURCE / ПАРАМ SOURCE
# - баланс по отдельным моделям идет от базы in2 через total
# - баланс по парам моделей считаем только внутри текущего семплинга
# =========================================================

def _model_diversity_score(row, model_stats, selected_model_counts, selected_model_pair_counts):
    sources = _task_sources(row)
    unique_sources = sorted(set(sources))

    base_plus_selected_after = []
    selected_after = []
    cold_unique_sources = 0

    for source_name in sources:
        base_total = int(_model_stat(model_stats, source_name)["total"])
        picked_total = int(selected_model_counts[source_name])

        base_plus_selected_after.append(base_total + picked_total + 1)
        selected_after.append(picked_total + 1)

    for source_name in unique_sources:
        if int(_model_stat(model_stats, source_name)["total"]) == 0:
            cold_unique_sources += 1

    pair_after = int(selected_model_pair_counts[_task_source_pair_key(row)]) + 1
    distinct_source_rank = 0 if len(unique_sources) == 2 else 1

    return (
        -cold_unique_sources,
        sum(base_plus_selected_after),
        max(base_plus_selected_after),
        pair_after,
        distinct_source_rank,
        sum(selected_after),
        max(selected_after),
    )


# =========================================================
# SCORE ПО WINS / LOSSES / DRAWS
# Считаем от базы in2 + текущий добор
# both_bad в этом блоке не участвует
# =========================================================

def _model_outcome_balance_score(row, current_model_outcomes):
    effect = _task_outcome_effect(row)

    if not effect:
        return (
            1,
            0,
            0,
            0,
            0,
        )

    touched_sources = sorted(effect.keys())

    after_missing = 0
    coverage_gain = 0
    after_spread = 0
    after_win_loss_gap = 0

    for source_name in touched_sources:
        before_stats = _model_stat(current_model_outcomes, source_name).copy()
        after_stats = before_stats.copy()

        for key, value in effect[source_name].items():
            after_stats[key] = int(after_stats.get(key, 0)) + int(value)

        before_missing = _outcome_missing_count(before_stats)
        current_after_missing = _outcome_missing_count(after_stats)

        after_missing += current_after_missing
        coverage_gain += before_missing - current_after_missing
        after_spread += _outcome_spread(after_stats)
        after_win_loss_gap += abs(int(after_stats["wins"]) - int(after_stats["losses"]))

    return (
        0,
        after_missing,
        -coverage_gain,
        after_spread,
        after_win_loss_gap,
    )


# =========================================================
# SCORE ПО ПУЛАМ
# Баланс по пулам считаем только внутри текущего добора
# - мягкий штраф после 2
# - жесткий фильтр после 8 включаем только если он не мешает добрать target
# =========================================================

def _pool_diversity_score(row, pool_counts):
    pool_id = str(row["poolId"])
    after = int(pool_counts[pool_id]) + 1
    soft_over = max(after - POOL_SOFT_LIMIT, 0)

    return (
        soft_over,
        after,
        pool_id,
    )


def _remaining_pool_capacity(remaining_df, pool_counts):
    if remaining_df.empty:
        return 0

    capacity = 0

    for pool_id, group in remaining_df.groupby("poolId", sort=False):
        pool_id = str(pool_id)
        already_selected = int(pool_counts[pool_id])
        free_slots = max(POOL_HARD_LIMIT - already_selected, 0)

        if free_slots <= 0:
            continue

        capacity += min(len(group), free_slots)

    return capacity


def _should_apply_pool_hard_limit(remaining_df, pool_counts, tasks_needed):
    if tasks_needed <= 0:
        return False

    # Если при hard cap по пулам уже нельзя добрать нужное число задач,
    # hard cap отключаем и оставляем только мягкий баланс по poolId.
    return _remaining_pool_capacity(remaining_df, pool_counts) >= int(tasks_needed)


def _apply_pool_hard_limit(candidates, remaining, pool_counts, tasks_needed):
    if not _should_apply_pool_hard_limit(
        remaining_df=remaining,
        pool_counts=pool_counts,
        tasks_needed=tasks_needed,
    ):
        return candidates

    under_hard_limit = candidates[
        candidates["poolId"].astype(str).apply(lambda x: int(pool_counts[str(x)]) < POOL_HARD_LIMIT)
    ].copy()

    if under_hard_limit.empty:
        return candidates

    return under_hard_limit


# =========================================================
# ОБЩИЙ SCORE
#
# ВАЖНО:
# Python сравнивает tuple слева направо.
# Значит порядок ниже = порядок важности.
# =========================================================

def _candidate_score(
    row,
    model_stats,
    current_model_outcomes,
    selected_model_counts,
    selected_model_pair_counts,
    current_bucket_counts,
    current_stage_counts,
    pool_counts,
):
    return (
        # 1. Сначала баланс по семействам
        *_family_balance_score(
            row=row,
            current_bucket_counts=current_bucket_counts,
        ),

        # 2. Потом баланс learn / validate
        *_stage_balance_score(
            row=row,
            current_stage_counts=current_stage_counts,
        ),

        # 3. Потом разнообразие моделей и пар моделей
        *_model_diversity_score(
            row=row,
            model_stats=model_stats,
            selected_model_counts=selected_model_counts,
            selected_model_pair_counts=selected_model_pair_counts,
        ),

        # 4. Потом баланс wins / losses / draws
        *_model_outcome_balance_score(
            row=row,
            current_model_outcomes=current_model_outcomes,
        ),

        # 5. И только потом пул
        *_pool_diversity_score(
            row=row,
            pool_counts=pool_counts,
        ),

        # 6. Случайный tie-break вместо taskId (бросаем кубик)
        random.random(),
    )


# =========================================================
# ОБНОВЛЕНИЕ СЧЕТЧИКОВ ПОСЛЕ ВЫБОРА
# =========================================================

def _update_selected_counters(
    best_row,
    selected_model_counts,
    selected_model_pair_counts,
    current_bucket_counts,
    current_stage_counts,
):
    for source_name in _task_sources(best_row):
        if source_name:
            selected_model_counts[source_name] += 1

    selected_model_pair_counts[_task_source_pair_key(best_row)] += 1

    for bucket_name in _task_buckets(best_row):
        if bucket_name:
            current_bucket_counts[bucket_name] += 1

    for stage_slot in _task_stage_slots(best_row):
        current_stage_counts[stage_slot] += 1


def _pick_best_candidate(
    candidates,
    model_stats,
    current_model_outcomes,
    selected_model_counts,
    selected_model_pair_counts,
    current_bucket_counts,
    current_stage_counts,
    pool_counts,
):
    if candidates.empty:
        return None

    best_idx = None
    best_score = None

    for idx, row in candidates.iterrows():
        score = _candidate_score(
            row=row,
            model_stats=model_stats,
            current_model_outcomes=current_model_outcomes,
            selected_model_counts=selected_model_counts,
            selected_model_pair_counts=selected_model_pair_counts,
            current_bucket_counts=current_bucket_counts,
            current_stage_counts=current_stage_counts,
            pool_counts=pool_counts,
        )

        if best_score is None or score < best_score:
            best_score = score
            best_idx = idx

    if best_idx is None:
        return None

    return candidates.loc[best_idx].copy()


def _register_selected_row(
    best_row,
    selected_rows,
    selected_keys,
    pool_counts,
    selected_model_counts,
    selected_model_pair_counts,
    current_bucket_counts,
    current_stage_counts,
    current_model_outcomes,
):
    selected_rows.append(best_row)
    selected_keys.add(best_row["row_key"])

    pool_counts[str(best_row["poolId"])] += 1

    _update_selected_counters(
        best_row=best_row,
        selected_model_counts=selected_model_counts,
        selected_model_pair_counts=selected_model_pair_counts,
        current_bucket_counts=current_bucket_counts,
        current_stage_counts=current_stage_counts,
    )

    _apply_outcome_effect(current_model_outcomes, _task_outcome_effect(best_row))


# =========================================================
# ПОДГОТОВКА ВЫХОДА
#
# На выход отдаем по одной строке на задачу:
# - первая accepted-строка задачи как носитель inputValues
# - плюс агрегированная мета по задаче
# - плюс список вердиктов всех редакторов этой задачи
# =========================================================

def _make_selected_tasks_rows(selected_df, raw_input_df):
    if selected_df.empty:
        return []

    meta_df = selected_df[
        [
            "row_key",
            "worker_cnt",
            "worker_ids",
            "source_1",
            "source_2",
            "source_1_family",
            "source_2_family",
            "priority_type",
            "aggregated_verdict",
            "aggregated_winner_family",
        ]
    ].copy()

    meta_df = meta_df.rename(
        columns={
            "source_1": "task_source_1",
            "source_2": "task_source_2",
            "source_1_family": "task_source_1_family",
            "source_2_family": "task_source_2_family",
            "priority_type": "task_priority_type",
        }
    )

    meta_df["selected_task_order"] = range(1, len(meta_df) + 1)

    raw_selected_df = _prepare_tasks_base_df(raw_input_df)
    raw_selected_df = raw_selected_df[
        raw_selected_df["row_key"].isin(meta_df["row_key"])
    ].copy()

    raw_selected_df = raw_selected_df.sort_values("_raw_output_order", kind="stable")

    # Вердикты всех редакторов задачи, чтобы ничего не потерять при схлопывании
    worker_verdicts = (
        raw_selected_df.groupby("row_key", sort=False)["worker_verdict"]
        .apply(lambda s: [str(v) for v in s.tolist()])
        .to_dict()
    )

    # Одна строка на задачу
    raw_selected_df = raw_selected_df.drop_duplicates(subset=["row_key"], keep="first").copy()

    merged = raw_selected_df.merge(
        meta_df,
        on="row_key",
        how="inner",
    )

    merged = merged.sort_values(
        ["selected_task_order", "_raw_output_order"],
        kind="stable",
    ).reset_index(drop=True)

    rows = []
    for _, r in merged.iterrows():
        row = {
            k: _clean_value(v)
            for k, v in r.to_dict().items()
            if k not in {"row_key", "_raw_output_order", "worker_ids"}
        }
        row["worker_ids_json"] = list(r["worker_ids"]) if isinstance(r["worker_ids"], list) else _clean_value(r["worker_ids"])
        row["worker_verdicts_json"] = list(worker_verdicts.get(r["row_key"], []))
        rows.append(row)

    return rows


# =========================================================
# ОСНОВНОЙ АЛГОРИТМ
#
# 1. Подготовка сырых строк
# 2. Схлопывание в задачи
# 3. Основной жадный отбор по моделям и пулам
# 4. Отдельный добор max 1 both_bad
#
# in3 больше не используется: баланса по воркерам нет.
# Параметр оставлен в сигнатуре ради совместимости с вызовом.
# =========================================================

def main(in1, in2, in3=None, mr_tables=None, token1=None, token2=None, param1=None, param2=None, html_file=None):
    raw_tasks_input_df = pd.DataFrame(in1)
    tasks_df = _normalize_tasks_input(raw_tasks_input_df)

    model_balance_df = _normalize_model_balance_input(pd.DataFrame(in2))

    if tasks_df.empty:
        return []

    total_target = _resolve_total_target(param1)
    if total_target <= 0:
        return []

    model_stats = _build_model_stats(model_balance_df)
    current_model_outcomes = _copy_model_outcomes(model_stats)
    current_model_outcomes = _ensure_sources_in_model_outcomes(current_model_outcomes, tasks_df)

    # База по семействам и stage идет из in2
    current_bucket_counts = Counter(_build_base_bucket_counts(model_balance_df))
    current_stage_counts = Counter(_build_base_stage_counts(model_balance_df))

    tasks_catalog = _build_tasks_catalog(tasks_df)
    if tasks_catalog.empty:
        return []

    # Эти счетчики считаем только внутри текущего семплинга
    selected_model_counts = Counter()
    selected_model_pair_counts = Counter()
    pool_counts = Counter()

    selected_rows = []
    selected_keys = set()

    available_both_bad = int((tasks_catalog["aggregated_verdict"] == "both_bad").sum())
    desired_both_bad = min(MAX_BOTH_BAD_TASKS, available_both_bad, total_target)
    normal_target = max(total_target - desired_both_bad, 0)

    # -------------------------------------------------
    # 1. Сначала обычный отбор без both_bad
    # -------------------------------------------------
    while len(selected_rows) < normal_target:
        remaining = tasks_catalog[~tasks_catalog["row_key"].isin(selected_keys)].copy()
        remaining = remaining[remaining["aggregated_verdict"] != "both_bad"].copy()

        if remaining.empty:
            break

        candidates = _apply_pool_hard_limit(
            candidates=remaining.copy(),
            remaining=remaining,
            pool_counts=pool_counts,
            tasks_needed=normal_target - len(selected_rows),
        )

        best_row = _pick_best_candidate(
            candidates=candidates,
            model_stats=model_stats,
            current_model_outcomes=current_model_outcomes,
            selected_model_counts=selected_model_counts,
            selected_model_pair_counts=selected_model_pair_counts,
            current_bucket_counts=current_bucket_counts,
            current_stage_counts=current_stage_counts,
            pool_counts=pool_counts,
        )

        if best_row is None:
            break

        _register_selected_row(
            best_row=best_row,
            selected_rows=selected_rows,
            selected_keys=selected_keys,
            pool_counts=pool_counts,
            selected_model_counts=selected_model_counts,
            selected_model_pair_counts=selected_model_pair_counts,
            current_bucket_counts=current_bucket_counts,
            current_stage_counts=current_stage_counts,
            current_model_outcomes=current_model_outcomes,
        )

    # -------------------------------------------------
    # 2. Потом добираем максимум 1 both_bad
    # -------------------------------------------------
    if desired_both_bad > 0 and len(selected_rows) < total_target:
        remaining = tasks_catalog[~tasks_catalog["row_key"].isin(selected_keys)].copy()
        remaining = remaining[remaining["aggregated_verdict"] == "both_bad"].copy()

        if not remaining.empty:
            candidates = _apply_pool_hard_limit(
                candidates=remaining.copy(),
                remaining=remaining,
                pool_counts=pool_counts,
                tasks_needed=total_target - len(selected_rows),
            )

            best_row = _pick_best_candidate(
                candidates=candidates,
                model_stats=model_stats,
                current_model_outcomes=current_model_outcomes,
                selected_model_counts=selected_model_counts,
                selected_model_pair_counts=selected_model_pair_counts,
                current_bucket_counts=current_bucket_counts,
                current_stage_counts=current_stage_counts,
                pool_counts=pool_counts,
            )

            if best_row is not None:
                _register_selected_row(
                    best_row=best_row,
                    selected_rows=selected_rows,
                    selected_keys=selected_keys,
                    pool_counts=pool_counts,
                    selected_model_counts=selected_model_counts,
                    selected_model_pair_counts=selected_model_pair_counts,
                    current_bucket_counts=current_bucket_counts,
                    current_stage_counts=current_stage_counts,
                    current_model_outcomes=current_model_outcomes,
                )

    if not selected_rows:
        return []

    selected_df = pd.DataFrame(selected_rows).reset_index(drop=True)
    return _make_selected_tasks_rows(selected_df, raw_tasks_input_df)
