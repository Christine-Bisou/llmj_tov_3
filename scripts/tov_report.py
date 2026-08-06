import math
import json
from collections import Counter

import numpy as np
import pandas as pd
import requests
from scipy.stats import ttest_1samp

import nirvana.job_context as nv


VERSION = 'URM LLMJ ToV 3.4'

# Аспекты в том порядке, в каком их показываем в отчёте.
# Ключ — как лежит в clc_metrics_* / pointwise_*, значение — подпись в тикете.
ASPECTS = [
    ('clarity',    'Ясность'),
    ('liveliness', 'Живость'),
    ('connect',    'Коннект'),
    ('overall',    'Общий'),
]

# Все 13 маркеров, порядок отчёта: сначала плюсовые, потом минусовые.
# is_positive определяет раскраску: у плюсовых лучше больше, у минусовых меньше.
MARKERS = [
    ('empathy',              '💚 Эмпатия',                                   True),
    ('subjectivity',         '🧚 Субъектность',                              True),
    ('tone_match',           '🍀 Попадание в тон и настроение',              True),
    ('humor_metaphors',      '🥒 Словесные пряности',                        True),
    ('critical_tone',        '🧊 Критично недопустимый тон',                 False),
    ('bad_intro',            '👺 Недочёты во вступлении',                    False),
    ('bad_proactivity',      '🥊 Недочёты в проактивности',                  False),
    ('over_emotional',       '💔 Гиперэмо',                                  False),
    ('stuffy_bureaucratic',  '📕 Тяжёлое восприятие',                        False),
    ('boundaries_violation', '💋 Нарушение личных границ пользователя',      False),
    ('template_phrases',     '🤖 Роботность',                                False),
    ('language_errors',      '😡 Ошибки языка',                              False),
    ('inconsistency',        '🚨 Неопределенность в обращении к пользователю', False),
]


def _as_dict(val):
    """Yson-колонка приезжает словарём, но после сериализации может быть строкой."""
    if isinstance(val, dict):
        return val
    if isinstance(val, (str, bytes)):
        try:
            parsed = json.loads(val)
        except Exception:
            return {}
        return parsed if isinstance(parsed, dict) else {}
    return {}


def _as_list(val):
    if isinstance(val, list):
        return [str(x) for x in val]
    if isinstance(val, (str, bytes)):
        try:
            parsed = json.loads(val)
        except Exception:
            return []
        return [str(x) for x in parsed] if isinstance(parsed, list) else []
    return []


def _marker_flags(row, idx):
    """Флаги маркеров одного ответа: {имя: bool}.

    Основной источник — markers_N_flags из склейки. Если его нет (старый
    формат таблицы), собираем из списка сработавших маркеров.
    """
    flags = _as_dict(row.get('markers_%d_flags' % idx))
    if flags:
        return {str(k): bool(v) for k, v in flags.items()}

    for col in ('markers_%d_list' % idx, 'model_%d_markers' % idx):
        lst = _as_list(row.get(col))
        if lst:
            return {name: True for name in lst}
    return {}


def _stars(row, idx):
    """Звёзды одного ответа: {аспект: float}. Ноль означает «не распарсилось»."""
    node = _as_dict(row.get('clc_metrics_%d' % idx))
    if not node:
        # в pointwise_* та же четвёрка, но с обвязкой: {'clarity': {'score': 4, ...}}
        rich = _as_dict(row.get('pointwise_%d' % idx))
        node = {k: _as_dict(v).get('score') for k, v in rich.items()}

    out = {}
    for key, _ in ASPECTS:
        try:
            val = float(node.get(key))
        except (TypeError, ValueError):
            continue
        if val > 0:
            out[key] = val
    return out


def _pvalue(diffs):
    """Парный t-тест: значимо ли среднее различие отличается от нуля."""
    diffs = np.array([d for d in diffs if d is not None], dtype=float)
    if len(diffs) < 2 or np.all(diffs == 0):
        return 1.0
    pval = float(ttest_1samp(diffs, 0.0).pvalue)
    return 1.0 if math.isnan(pval) else pval


def _paint(text, pval, m1_better, for_m1):
    """Красим только значимые различия: <0.01 — насыщенно, <0.05 — мягко."""
    if pval >= 0.05:
        return text
    strong = pval < 0.01
    good = 'green' if strong else 'yellow'
    bad = 'red' if strong else 'orange'
    winning = m1_better if for_m1 else not m1_better
    return '**{%s}(%s)**' % (good if winning else bad, text)


def _source_names(series):
    """Сорсы одной стороны замера: [(имя, сколько строк)], частые первыми."""
    if series is None:
        return []
    values = [str(v).strip() for v in series if str(v).strip() not in ('', 'None', 'nan')]
    return Counter(values).most_common()


def main(in1, in2, in3, mr_tables, token1=None, token2=None,
         param1=None, param2=None, html_file=None):
    df = pd.DataFrame(in1)

    total_cnt = len(df)
    if total_cnt == 0:
        return [], []

    # Имена моделей берём из самих данных — answer_source_1 / answer_source_2
    # едут из корзинки и совпадают с тем, что реально сравнивалось. Глобальные
    # параметры графа остаются подстраховкой на случай пустой колонки.
    src_1 = _source_names(df.get('answer_source_1'))
    src_2 = _source_names(df.get('answer_source_2'))
    m1_name = src_1[0][0] if src_1 else '${global.model_1_name}'.strip()
    m2_name = src_2[0][0] if src_2 else '${global.model_2_name}'.strip()

    # ---------------------------------------------------------------- вердикты
    def classify_resolution(row):
        meta = _as_dict(row.get('meta_info'))
        md = str(meta.get('model_winner_direct', '')).strip()
        mrn = str(meta.get('model_winner_reversed_normalized', '')).strip()
        final_winner = str(row.get('tov_winner', 'draw')).strip()

        if md == mrn:
            conf = 'confident'
        elif md in ('draw', 'tie') or mrn in ('draw', 'tie'):
            conf = 'soft'
        else:
            conf = 'conflict'
        return pd.Series([conf, final_winner])

    df[['confidence', 'final_winner']] = df.apply(classify_resolution, axis=1)

    def calc_stats(series):
        if len(series) == 0:
            return 0.0, 0.0, 0.0, 1.0
        scores = []
        for w in series:
            if w == 'model_1':
                scores.append(1.0)
            elif w == 'model_2':
                scores.append(0.0)
            else:
                scores.append(0.5)

        scores = np.array(scores)
        count = len(scores)
        w1, w2 = np.mean(scores), 1.0 - np.mean(scores)
        draw_rate = np.sum(scores == 0.5) / count

        p_val = 1.0
        if count >= 2 and np.std(scores, ddof=1) > 0:
            p_val = float(ttest_1samp(scores, 0.5).pvalue)
        if math.isnan(p_val):
            p_val = 1.0
        return w1, w2, draw_rate, p_val

    winrate_m1, winrate_m2, draw_rate, p_value = calc_stats(df['final_winner'])

    m1_color = _paint('%.1f%%' % (winrate_m1 * 100), p_value, winrate_m1 > winrate_m2, True)
    m2_color = _paint('%.1f%%' % (winrate_m2 * 100), p_value, winrate_m1 > winrate_m2, False)
    overall_winner = (
        m1_name if winrate_m1 > winrate_m2
        else (m2_name if winrate_m2 > winrate_m1 else 'Ничья')
    )

    # ------------------------------------------------------------------ звёзды
    stars_1 = [_stars(row, 1) for _, row in df.iterrows()]
    stars_2 = [_stars(row, 2) for _, row in df.iterrows()]

    pw_lines = [
        '| Аспект | %s | %s |' % (m1_name, m2_name),
        '|---|---|---|',
    ]
    for key, title in ASPECTS:
        v1 = [s[key] for s in stars_1 if key in s]
        v2 = [s[key] for s in stars_2 if key in s]
        if not v1 and not v2:
            pw_lines.append('| %s | — | — |' % title)
            continue

        avg1 = float(np.mean(v1)) if v1 else 0.0
        avg2 = float(np.mean(v2)) if v2 else 0.0
        # пары, где обе звезды на месте: только на них считается значимость
        diffs = [a[key] - b[key] for a, b in zip(stars_1, stars_2)
                 if key in a and key in b]
        pval = _pvalue(diffs)

        c1 = _paint('%.2f' % avg1, pval, avg1 > avg2, True)
        c2 = _paint('%.2f' % avg2, pval, avg1 > avg2, False)
        pw_lines.append('| %s | %s | %s |' % (title, c1, c2))

    pw_table = '\n'.join(pw_lines)

    # ----------------------------------------------------------------- маркеры
    flags_1 = [_marker_flags(row, 1) for _, row in df.iterrows()]
    flags_2 = [_marker_flags(row, 2) for _, row in df.iterrows()]

    m1_perc = {}
    m2_perc = {}
    for name, _, _ in MARKERS:
        m1_perc[name] = sum(1 for f in flags_1 if f.get(name)) / total_cnt
        m2_perc[name] = sum(1 for f in flags_2 if f.get(name)) / total_cnt

    mk_lines = [
        '| Маркер | %s | %s |' % (m1_name, m2_name),
        '|---|---|---|',
    ]
    for name, title, is_positive in MARKERS:
        v1, v2 = m1_perc[name], m2_perc[name]
        diffs = [int(bool(a.get(name))) - int(bool(b.get(name)))
                 for a, b in zip(flags_1, flags_2)]
        pval = _pvalue(diffs)
        m1_better = (v1 > v2) if is_positive else (v1 < v2)

        c1 = _paint('%.1f%%' % (v1 * 100), pval if v1 != v2 else 1.0, m1_better, True)
        c2 = _paint('%.1f%%' % (v2 * 100), pval if v1 != v2 else 1.0, m1_better, False)
        mk_lines.append('| %s | %s | %s |' % (title, c1, c2))

    marker_details = (
        '%s\n\nДоля заданий, в которых маркер сработал: 35%% — значит в 35 '
        'заданиях из 100. Первые четыре маркера плюсовые (больше — лучше), '
        'остальные минусовые (меньше — лучше); зелёным подсвечена та модель, '
        'у которой значимо лучше.\n' % '\n'.join(mk_lines)
    )

    # В корзинке может лежать не одна пара сорсов: тогда в шапке таблиц стоит
    # самый частый, а остальные ушли бы молча — поэтому выписываем весь состав.
    def _mix(src):
        return ', '.join('%s (%d)' % (name, cnt) for name, cnt in src)

    mixed_note = ''
    if len(src_1) > 1 or len(src_2) > 1:
        mixed_note = (
            '* **Внимание, сорсы в замере смешаны:** слева — %s; справа — %s\n'
            % (_mix(src_1), _mix(src_2))
        )

    # ------------------------------------------------------------------- отчёт
    def cut(title, text):
        return '\n{%% cut "%s" %%}\n\n%s\n\n{%% endcut %%}\n' % (title, text)

    basket_path = param1 if param1 else 'Неизвестный путь'
    ctx = nv.context()
    nirvana_url = ctx.get_meta().get_workflow_url() if ctx else 'Локальный запуск'

    main_table = (
        '| Модели | Винрейт (ничьи за 0.5) | p-value |\n'
        '|---|---|---|\n'
        '| **%s** vs **%s** | %s vs %s | `%.4f` |'
        % (m1_name, m2_name, m1_color, m2_color, p_value)
    )

    report_text = """# Результаты замера ToV (llmj)

Версия: **%s**

### Оценки по аспектам (среднее по замеру)

%s

Победитель: **%s**

%s

* **Доля ничьих:** %.1f%%
* **Размер корзинки:** %d
* **Название таблички:** %s
* **Граф:** %s
%s""" % (VERSION, pw_table, overall_winner, main_table,
         draw_rate * 100, total_cnt, basket_path, nirvana_url, mixed_note)

    report_text += cut('Маркеры ToV', marker_details)

    conf_cnt = len(df[df['confidence'] == 'confident'])
    soft_cnt = len(df[df['confidence'] == 'soft'])
    conflict_cnt = len(df[df['confidence'] == 'conflict'])

    def p(val, tot):
        return '%.1f%%' % (val / tot * 100) if tot else '0.0%'

    funnel_details = """
| Согласованность проходов | Кол-во запросов | Описание |
|---|---|---|
| **Уверенные** | %d (%s) | Прямой и обратный выбрали одну модель (или оба Ничью) |
| **Мягкие** | %d (%s) | Один проход выбрал модель, второй — Ничью |
| **Конфликты** | %d (%s) | Выбраны разные модели (сведено в Ничью) |
""" % (conf_cnt, p(conf_cnt, total_cnt),
       soft_cnt, p(soft_cnt, total_cnt),
       conflict_cnt, p(conflict_cnt, total_cnt))

    report_text += cut('Аналитика вердиктов', funnel_details)

    # Тикет — из param2, токен — из token2. Каждый отказ печатаем: раньше
    # отправка молчала одинаково и когда флаг выключен, и когда Стартрек
    # ответил 404, и разбираться было не с чем.
    ticket = str(param2 or '').strip()
    p_flag = str('${global.post_to_ticket_and_datalens}').strip().lower()

    if p_flag.startswith('${'):
        # подстановка не сработала — считаем, что флаг не задан
        print('POST SKIPPED: флаг post_to_ticket_and_datalens не подставился (%r)' % p_flag)
    elif p_flag not in ('true', '1', 'yes'):
        print('POST SKIPPED: флаг post_to_ticket_and_datalens = %r' % p_flag)
    elif not ticket or ticket.startswith('${'):
        print('POST SKIPPED: param2 (ключ тикета) пустой или не подставился: %r' % param2)
    elif not token2:
        print('POST SKIPPED: token2 не передан в кубик')
    else:
        url = 'https://st-api.yandex-team.ru/v2/issues/%s/comments' % ticket
        try:
            resp = requests.post(
                url,
                json={'text': report_text, 'markupType': 'markdown'},
                headers={'Authorization': 'OAuth ' + str(token2).strip()},
                timeout=30,
            )
            if resp.status_code >= 300:
                print('POST FAILED: %s -> %s %s' % (url, resp.status_code, resp.text[:1000]))
            else:
                print('POST OK: комментарий в %s' % ticket)
        except Exception as e:
            print('POST ERROR: %s -> %s' % (url, e))

    out_df = df.drop(columns=['confidence', 'final_winner'], errors='ignore')
    return out_df.to_dict('records'), [{
        'version': VERSION,
        'winrate_m1': winrate_m1,
        'winrate_m2': winrate_m2,
        'p_value': p_value,
        'm1_markers_perc': m1_perc,
        'm2_markers_perc': m2_perc,
    }]
