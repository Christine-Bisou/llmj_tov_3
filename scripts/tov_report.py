"""Отчёт по замеру ToV: винрейт моделей и бинарные маркеры.

Маркер считается выставленным, если его поставил хотя бы один из проходов
(прямой или обратный). Процент по маркеру — доля ответов модели, в которых
маркер присутствует, от размера корзинки.

Кубик Nirvana вызывает main(); тот же файл запускается локально:

    python3 scripts/tov_report.py path/to/output1.xlsx
"""

import math
import sys

import numpy as np
import pandas as pd
import requests
from scipy.stats import ttest_1samp

try:
    import nirvana.job_context as nv
except ImportError:  # локальный запуск
    nv = None

# Имена маркеров первого этапа — те же, что в sql/judge_merge_pretty.sql.
POSITIVE_MARKERS = ['empathy', 'subjectivity', 'tone_match', 'humor_metaphors']
NEGATIVE_MARKERS = ['critical_tone', 'bad_intro', 'bad_proactivity', 'over_emotional',
                    'stuffy_bureaucratic', 'boundaries_violation', 'template_phrases',
                    'language_errors', 'inconsistency']
MARKER_NAMES = POSITIVE_MARKERS + NEGATIVE_MARKERS

# Аспекты второго этапа (звёзды).
ASPECTS = ['clarity', 'connect', 'liveliness', 'overall']
ASPECT_RU = {'clarity': 'Ясность', 'connect': 'Попадание в собеседника',
             'liveliness': 'Живость', 'overall': 'Общая оценка'}

# Ключи внутри маркера, которые хранят вердикт отдельного прохода.
PASS_KEYS = ('is_present', 'direct', 'reversed')


def _norm_verdict(val):
    """'tie' и пустое значение — та же ничья, что и 'draw'."""
    val = str(val).strip()
    return 'draw' if val in ('tie', 'both_bad', 'skip', '') else val


def _as_bool(val):
    if isinstance(val, bool):
        return val
    if isinstance(val, (int, float)) and not isinstance(val, bool):
        return bool(val)
    if isinstance(val, bytes):
        val = val.decode('utf-8', errors='ignore')
    if isinstance(val, str):
        return val.strip().lower() in ('true', '%true', '1', 'yes')
    return False


def _parse_yson_flags(text):
    """Разбор YSON-строки вида {"bad_intro"=%true;...} — нужен при чтении выгрузки."""
    import re

    found = {}
    for name, val in re.findall(r'"?([a-zA-Z_0-9]+)"?=%(true|false)', text):
        if name in MARKER_NAMES:
            found[name] = found.get(name, False) or (val == 'true')
    return found


def _collect(source, acc):
    """Складывает в acc флаги маркеров из любого представления, которое встречается в таблице."""
    if source is None:
        return
    if isinstance(source, bytes):
        source = source.decode('utf-8', errors='ignore')
    if isinstance(source, str):
        for name, flag in _parse_yson_flags(source).items():
            acc[name] = acc[name] or flag
        return
    if isinstance(source, (list, tuple, set)):
        # markers_N_list — просто перечень сработавших маркеров
        for name in source:
            name = name.decode('utf-8', errors='ignore') if isinstance(name, bytes) else str(name)
            if name in acc:
                acc[name] = True
        return
    if isinstance(source, dict):
        for name, node in source.items():
            name = name.decode('utf-8', errors='ignore') if isinstance(name, bytes) else str(name)
            if name not in acc:
                continue
            if isinstance(node, dict):
                # {is_present, explanation} или {direct, reversed}: хватит любого прохода
                acc[name] = acc[name] or any(_as_bool(node.get(k)) for k in PASS_KEYS)
            else:
                acc[name] = acc[name] or _as_bool(node)


def marker_flags(row, idx):
    """Флаги маркеров для ответа модели idx (1 или 2), объединённые по всем проходам."""
    acc = {name: False for name in MARKER_NAMES}
    for column in (f'markers_{idx}_flags', f'markers_{idx}', f'markers_{idx}_list',
                   f'ext_markers_{idx}', f'markers_{idx}_flags_direct',
                   f'markers_{idx}_flags_reversed'):
        _collect(row.get(column), acc)
    return acc


def _yson_str(node, key):
    """Значение строкового поля: и для распарсенного словаря, и для YSON-строки.

    В YSON голые слова пишутся без кавычек (`"model_winner_direct"=tie;`),
    поэтому берём оба варианта записи значения.
    """
    if isinstance(node, dict):
        val = node.get(key, '')
        if isinstance(val, bytes):
            val = val.decode('utf-8', errors='ignore')
        return str(val).strip()
    if isinstance(node, bytes):
        node = node.decode('utf-8', errors='ignore')
    if isinstance(node, str):
        import re

        m = re.search(r'"?%s"?=(?:"([^"]*)"|([A-Za-z_0-9.\-]+))' % re.escape(key), node)
        if not m:
            return ''
        return (m.group(1) if m.group(1) is not None else m.group(2)).strip()
    return ''


def winrate_stats(winners):
    """Винрейт первой модели (ничья за 0.5), доля ничьих и p-value против 0.5."""
    scores = np.array([{'model_1': 1.0, 'model_2': 0.0}.get(str(w).strip(), 0.5) for w in winners])
    if len(scores) == 0:
        return 0.0, 0.0, 0.0, 1.0
    wr1 = float(scores.mean())
    draw_rate = float((scores == 0.5).mean())
    p_val = 1.0
    if len(scores) >= 2 and scores.std(ddof=1) > 0:
        p_val = float(ttest_1samp(scores, 0.5).pvalue)
    if math.isnan(p_val):
        p_val = 1.0
    return wr1, 1.0 - wr1, draw_rate, p_val


def marker_stats(flags_1, flags_2):
    """По каждому маркеру: доли у обеих моделей и p-value парного сравнения."""
    total = len(flags_1)
    stats = {}
    for name in MARKER_NAMES:
        a = np.array([int(f[name]) for f in flags_1])
        b = np.array([int(f[name]) for f in flags_2])
        diffs = a - b
        if total == 0 or np.all(diffs == 0) or diffs.std(ddof=1) == 0:
            p_val = 1.0
        else:
            p_val = float(ttest_1samp(diffs, 0.0).pvalue)
            if math.isnan(p_val):
                p_val = 1.0
        stats[name] = {
            'm1_cnt': int(a.sum()), 'm2_cnt': int(b.sum()),
            'm1_perc': float(a.mean()) if total else 0.0,
            'm2_perc': float(b.mean()) if total else 0.0,
            'only_m1': int(((a == 1) & (b == 0)).sum()),
            'only_m2': int(((a == 0) & (b == 1)).sum()),
            'both': int(((a == 1) & (b == 1)).sum()),
            'p_value': p_val,
        }
    return stats


def _aspect_scores(node):
    """Оценки по аспектам из pointwise_N: и словарь, и YSON-строка."""
    out = {}
    if isinstance(node, dict):
        for asp in ASPECTS:
            val = node.get(asp)
            if isinstance(val, dict):  # {score: 4, reasoning: ...}
                val = val.get('score')
            try:
                out[asp] = float(val)
            except (TypeError, ValueError):
                pass
        return out
    if isinstance(node, bytes):
        node = node.decode('utf-8', errors='ignore')
    if isinstance(node, str):
        import re

        for asp, val in re.findall(r'"?(%s)"?=(-?\d+(?:\.\d+)?)' % '|'.join(ASPECTS), node):
            out[asp] = float(val)
    return out


def pointwise_stats(records):
    """По каждому аспекту: средние обеих моделей, разбивка побед и p-value."""
    stats = {}
    for asp in ASPECTS:
        pairs = []
        for row in records:
            a = _aspect_scores(row.get('pointwise_1', {})).get(asp)
            b = _aspect_scores(row.get('pointwise_2', {})).get(asp)
            if a is not None and b is not None:
                pairs.append((a, b))
        if not pairs:
            continue
        a = np.array([x for x, _ in pairs])
        b = np.array([y for _, y in pairs])
        diff = a - b
        p_val = 1.0
        if len(diff) >= 2 and diff.std(ddof=1) > 0:
            p_val = float(ttest_1samp(diff, 0.0).pvalue)
        if math.isnan(p_val):
            p_val = 1.0
        stats[asp] = {
            'cnt': len(pairs),
            'm1_mean': float(a.mean()), 'm2_mean': float(b.mean()),
            'delta': float(b.mean() - a.mean()),
            'm1_better': float((diff > 0).mean()),
            'tie': float((diff == 0).mean()),
            'm2_better': float((diff < 0).mean()),
            'm1_top': float((a == 5).mean()), 'm2_top': float((b == 5).mean()),
            'm1_low': float((a <= 3).mean()), 'm2_low': float((b <= 3).mean()),
            'p_value': p_val,
        }
    return stats


def pass_stats(records):
    """Вердикты отдельных проходов и позиционная предвзятость судьи."""
    direct, rev_raw, rev_norm = [], [], []
    for row in records:
        meta = row.get('meta_info', {})
        direct.append(_norm_verdict(_yson_str(meta, 'model_winner_direct')))
        rev_raw.append(_norm_verdict(_yson_str(meta, 'model_winner_reversed')))
        rev_norm.append(_norm_verdict(_yson_str(meta, 'model_winner_reversed_normalized')))

    total = len(direct)
    if total == 0:
        return {}

    def side(winners):
        wr1, wr2, draw_rate, p_val = winrate_stats(winners)
        return {'winrate_m1': wr1, 'winrate_m2': wr2, 'draw_rate': draw_rate, 'p_value': p_val,
                'wins_m1': winners.count('model_1'), 'wins_m2': winners.count('model_2'),
                'draws': winners.count('draw')}

    # первым судье показан answer_1 в прямом проходе и answer_2 в обратном
    first = direct.count('model_1') + rev_raw.count('model_1')
    second = direct.count('model_2') + rev_raw.count('model_2')
    shown = 2 * total
    return {
        'direct': side(direct),
        'reversed': side(rev_norm),
        'agreement': sum(a == b for a, b in zip(direct, rev_norm)) / total,
        'first_position': first / shown,
        'second_position': second / shown,
        'position_draw': (shown - first - second) / shown,
    }


def _colorize(value, is_winner, p_val):
    val_str = f"{value * 100:.1f}%"
    if p_val is None or math.isnan(p_val) or p_val >= 0.05:
        return val_str
    color = 'green' if is_winner else 'red'
    if p_val >= 0.01:
        color = 'yellow' if is_winner else 'orange'
    return f"**{{{color}}}({val_str})**"


def _cut(title, text):
    return f"\n{{% cut \"{title}\" %}}\n\n{text}\n\n{{% endcut %}}\n"


def _marker_table(stats, markers_list, is_positive, m1_name, m2_name):
    lines = [f"| Маркер | {m1_name} (%) | {m2_name} (%) | Только у 1 | Только у 2 | У обеих | p-value |",
             "|---|---|---|---|---|---|---|"]
    actual = [m for m in markers_list if stats[m]['m1_cnt'] or stats[m]['m2_cnt']]
    if not actual:
        return "_Маркеров не зафиксировано_\n"

    for name in actual:
        s = stats[name]
        v1, v2, p_val = s['m1_perc'], s['m2_perc'], s['p_value']
        c1 = f"{v1 * 100:.1f}% ({s['m1_cnt']})"
        c2 = f"{v2 * 100:.1f}% ({s['m2_cnt']})"
        if p_val < 0.05 and v1 != v2:
            strong = p_val < 0.01
            good = 'green' if strong else 'yellow'
            bad = 'red' if strong else 'orange'
            m1_better = (v1 > v2) if is_positive else (v1 < v2)
            if m1_better:
                c1, c2 = f"**{{{good}}}({c1})**", f"**{{{bad}}}({c2})**"
            else:
                c1, c2 = f"**{{{bad}}}({c1})**", f"**{{{good}}}({c2})**"
        lines.append(f"| `{name}` | {c1} | {c2} | {s['only_m1']} | {s['only_m2']} | {s['both']} | `{p_val:.4f}` |")
    return "\n".join(lines) + "\n"


def build_report(records, m1_name, m2_name, basket_path='Неизвестный путь', nirvana_url='Локальный запуск'):
    """Возвращает (markdown-отчёт, словарь метрик)."""
    total_cnt = len(records)
    if total_cnt == 0:
        return '', {}

    winners, confidences = [], []
    flags_1, flags_2 = [], []
    for row in records:
        winners.append(str(row.get('tov_winner', 'draw')).strip())

        meta = row.get('meta_info', {})
        direct = _norm_verdict(_yson_str(meta, 'model_winner_direct'))
        reversed_norm = _norm_verdict(_yson_str(meta, 'model_winner_reversed_normalized'))
        if direct == reversed_norm:
            confidences.append('confident')
        elif direct in ('draw', 'tie') or reversed_norm in ('draw', 'tie'):
            confidences.append('soft')
        else:
            confidences.append('conflict')

        flags_1.append(marker_flags(row, 1))
        flags_2.append(marker_flags(row, 2))

    winrate_m1, winrate_m2, draw_rate, p_value = winrate_stats(winners)
    stats = marker_stats(flags_1, flags_2)
    aspects = pointwise_stats(records)
    passes = pass_stats(records)

    m1_color = _colorize(winrate_m1, winrate_m1 > winrate_m2, p_value)
    m2_color = _colorize(winrate_m2, winrate_m2 > winrate_m1, p_value)
    overall_winner = m1_name if winrate_m1 > winrate_m2 else (m2_name if winrate_m2 > winrate_m1 else 'Ничья')

    main_table = f"""| Модели | Винрейт (ничьи за 0.5) | p-value |
|---|---|---|
| **{m1_name}** vs **{m2_name}** | {m1_color} vs {m2_color} | `{p_value:.4f}` |"""

    report_text = f"""# Результаты замера ToV (llmj)

Победитель: **{overall_winner}**

{main_table}

* **Доля ничьих:** {draw_rate * 100:.1f}%
* **Размер корзинки:** {total_cnt}
* **Название таблички:** {basket_path}
* **Граф:** {nirvana_url}
"""

    marker_details = f"""Доля ответов модели, в которых маркер присутствует хотя бы по одному проходу.

### Позитивные маркеры (больше — лучше)
{_marker_table(stats, POSITIVE_MARKERS, True, m1_name, m2_name)}
### Критические и негативные (меньше — лучше)
{_marker_table(stats, NEGATIVE_MARKERS, False, m1_name, m2_name)}"""
    report_text += _cut('Маркеры ToV', marker_details)

    if aspects:
        lines = [f"| Аспект | {m1_name} | {m2_name} | Δ | {m1_name} выше | Поровну | {m2_name} выше | p-value |",
                 "|---|---|---|---|---|---|---|---|"]
        for asp in ASPECTS:
            s = aspects.get(asp)
            if not s:
                continue
            delta = f"{s['delta']:+.2f}".replace('+0.00', '0.00')
            lines.append(
                f"| {ASPECT_RU[asp]} | {s['m1_mean']:.2f} | {s['m2_mean']:.2f} | {delta} | "
                f"{s['m1_better'] * 100:.1f}% | {s['tie'] * 100:.1f}% | {s['m2_better'] * 100:.1f}% | "
                f"`{s['p_value']:.4f}` |")
        aspect_details = ("Средний балл по пятибалльной шкале, склеенный из двух проходов.\n\n"
                          + "\n".join(lines) + "\n")
        report_text += _cut('Оценки по аспектам (pointwise)', aspect_details)

    if passes:
        d, r = passes['direct'], passes['reversed']
        pass_details = f"""
| Проход | {m1_name} | {m2_name} | Ничьи | p-value |
|---|---|---|---|---|
| Прямой | {d['winrate_m1'] * 100:.1f}% ({d['wins_m1']}) | {d['winrate_m2'] * 100:.1f}% ({d['wins_m2']}) | {d['draws']} | `{d['p_value']:.4f}` |
| Обратный | {r['winrate_m1'] * 100:.1f}% ({r['wins_m1']}) | {r['winrate_m2'] * 100:.1f}% ({r['wins_m2']}) | {r['draws']} | `{r['p_value']:.4f}` |

* **Согласие проходов:** {passes['agreement'] * 100:.1f}%
* **Позиционная предвзятость:** первый показанный ответ побеждает в {passes['first_position'] * 100:.1f}% сравнений, второй — в {passes['second_position'] * 100:.1f}%, ничьи {passes['position_draw'] * 100:.1f}%
"""
        report_text += _cut('Проходы судьи (pairwise)', pass_details)

    conf_cnt = confidences.count('confident')
    soft_cnt = confidences.count('soft')
    conflict_cnt = confidences.count('conflict')

    def p(val):
        return f"{val / total_cnt * 100:.1f}%" if total_cnt else '0.0%'

    funnel_details = f"""
| Согласованность проходов | Кол-во запросов | Описание |
|---|---|---|
| **Уверенные** | {conf_cnt} ({p(conf_cnt)}) | Прямой и обратный выбрали одну модель (или оба Ничью) |
| **Мягкие** | {soft_cnt} ({p(soft_cnt)}) | Один проход выбрал модель, второй — Ничью |
| **Конфликты** | {conflict_cnt} ({p(conflict_cnt)}) | Выбраны разные модели |
"""
    report_text += _cut('Аналитика вердиктов', funnel_details)

    metrics = {
        'winrate_m1': winrate_m1,
        'winrate_m2': winrate_m2,
        'draw_rate': draw_rate,
        'p_value': p_value,
        'total_cnt': total_cnt,
        'confident_cnt': conf_cnt,
        'soft_cnt': soft_cnt,
        'conflict_cnt': conflict_cnt,
        'markers': stats,
        'aspects': aspects,
        'passes': passes,
        'm1_markers_perc': {k: v['m1_perc'] for k, v in stats.items()},
        'm2_markers_perc': {k: v['m2_perc'] for k, v in stats.items()},
    }
    return report_text, metrics


def main(in1, in2, in3, mr_tables, token1=None, token2=None, param1=None, param2=None, html_file=None):
    df = pd.DataFrame(in1)
    if len(df) == 0:
        return [], []

    m1_name = '${global.model_1_name}'.strip()
    m2_name = '${global.model_2_name}'.strip()

    ctx = nv.context() if nv else None
    nirvana_url = ctx.get_meta().get_workflow_url() if ctx else 'Локальный запуск'

    report_text, metrics = build_report(
        df.to_dict('records'), m1_name, m2_name,
        basket_path=param1 if param1 else 'Неизвестный путь',
        nirvana_url=nirvana_url,
    )

    p_flag = '${global.post_to_ticket_and_datalens}'.strip().lower()
    if param2 and token2 and p_flag in ('true', '1'):
        try:
            requests.post(
                f"https://st-api.yandex-team.ru/v2/issues/{param2}/comments",
                json={'text': report_text, 'markupType': 'markdown'},
                headers={'Authorization': 'OAuth ' + token2},
            )
        except Exception as e:
            print(f"API Error: {e}")

    return df.to_dict('records'), [metrics]


def _load_table(path):
    if path.endswith(('.xlsx', '.xlsm')):
        df = pd.read_excel(path)
    else:
        df = pd.read_csv(path)
    # выгрузка иногда несёт первой строкой схему колонок ("any" / "string")
    return df[df['tov_winner'].isin(['model_1', 'model_2', 'draw'])].reset_index(drop=True)


def _cli(path):
    df = _load_table(path)
    m1_name = str(df['answer_source_1'].iloc[0]) if 'answer_source_1' in df else 'model_1'
    m2_name = str(df['answer_source_2'].iloc[0]) if 'answer_source_2' in df else 'model_2'
    report_text, metrics = build_report(df.to_dict('records'), m1_name, m2_name, basket_path=path)
    print(report_text)
    if metrics.get('aspects'):
        print(pd.DataFrame([
            {'аспект': ASPECT_RU[a], f'{m1_name}': round(s['m1_mean'], 2),
             f'{m2_name}': round(s['m2_mean'], 2), 'Δ': round(s['delta'], 3),
             '1 выше %': round(s['m1_better'] * 100, 1), 'поровну %': round(s['tie'] * 100, 1),
             '2 выше %': round(s['m2_better'] * 100, 1), 'p_value': round(s['p_value'], 6)}
            for a, s in metrics['aspects'].items()]).to_string(index=False))
        print()
    rows = [{'marker': name,
             f'{m1_name} %': round(s['m1_perc'] * 100, 1), f'{m1_name} n': s['m1_cnt'],
             f'{m2_name} %': round(s['m2_perc'] * 100, 1), f'{m2_name} n': s['m2_cnt'],
             'only_1': s['only_m1'], 'only_2': s['only_m2'], 'both': s['both'],
             'p_value': round(s['p_value'], 6)}
            for name, s in metrics['markers'].items()]
    print(pd.DataFrame(rows).to_string(index=False))


if __name__ == '__main__':
    if len(sys.argv) != 2:
        sys.exit('usage: python3 scripts/tov_report.py <table.xlsx|table.csv>')
    _cli(sys.argv[1])
