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

# Ключи внутри маркера, которые хранят вердикт отдельного прохода.
PASS_KEYS = ('is_present', 'direct', 'reversed')


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
    """Значение строкового поля: и для распарсенного словаря, и для YSON-строки."""
    if isinstance(node, dict):
        val = node.get(key, '')
        if isinstance(val, bytes):
            val = val.decode('utf-8', errors='ignore')
        return str(val).strip()
    if isinstance(node, bytes):
        node = node.decode('utf-8', errors='ignore')
    if isinstance(node, str):
        import re

        m = re.search(r'"?%s"?="([^"]*)"' % re.escape(key), node)
        return m.group(1).strip() if m else ''
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
        direct = _yson_str(meta, 'model_winner_direct')
        reversed_norm = _yson_str(meta, 'model_winner_reversed_normalized')
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
