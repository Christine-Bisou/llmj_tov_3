# -*- coding: utf-8 -*-
"""Приклеивает html-рендеры ответов к таблице разметки.

in1 — таблица с отрендеренными ответами (answer_1 / answer_2 — html страницы);
in3 — таблица разметки (answer_1 / answer_2 — текст, answer_source_1 / _2 — модели).
Склейка идёт по rownum; всё из in3 сохраняется как есть, добавляются только
answer_1_html и answer_2_html.

Порядок ответов в in1 не обязан совпадать с порядком в in3: пара могла быть
перемешана при шафле. Поэтому перед выдачей пара сверяется по тексту ответа —
он лежит в html в атрибуте data-model-answer — и при расхождении html-колонки
меняются местами, чтобы answer_N_html соответствовал answer_source_N.
"""

import re
import html as html_lib
from difflib import SequenceMatcher

_MODEL_ANSWER_RE = re.compile(r'data-model-answer="([^"]*)"', re.DOTALL)

# Сравниваем только начало текста: полное сравнение длинных ответов дорого,
# а первых сотен символов хватает, чтобы отличить один ответ от другого.
_CMP_LEN = 600

# Порог на ОДИН ответ; для пары сравниваем сумму двух, отсюда умножение на 2.
_MATCH_MIN = 0.6


def _norm(text):
    if not text:
        return ''
    text = html_lib.unescape(str(text))
    return re.sub(r'\s+', ' ', text).strip().lower()[:_CMP_LEN]


def _answer_text_from_html(page):
    """Текст ответа из data-model-answer — это исходный markdown до рендера."""
    if not page:
        return ''
    found = _MODEL_ANSWER_RE.search(str(page))
    return found.group(1) if found else ''


def _ratio(a, b):
    if not a or not b:
        return 0.0
    if a == b:
        return 1.0
    return SequenceMatcher(None, a, b).ratio()


def _rownum(rec, fallback):
    """rownum, если он есть; иначе порядковый номер строки."""
    if isinstance(rec, dict) and rec.get('rownum') is not None:
        return rec['rownum']
    return fallback


def _html(rec, num):
    """html лежит либо в answer_N_html, либо (чаще) прямо в answer_N."""
    return rec.get('answer_%d_html' % num) or rec.get('answer_%d' % num)


def main(in1, in2, in3, mr_tables, token1=None, token2=None,
         param1=None, param2=None, html_file=None):
    by_rownum = {}
    for i, rec in enumerate(in1):
        by_rownum[_rownum(rec, i)] = rec

    result = []
    total = no_pair = swapped_cnt = unverified = 0

    for i, row in enumerate(in3):
        total += 1
        out = dict(row)
        key = _rownum(row, i)
        src = by_rownum.get(key)

        if src is None:
            # строки без пары не выкидываем: пусть видно, что html не доехал
            no_pair += 1
            out['answer_1_html'] = None
            out['answer_2_html'] = None
            result.append(out)
            continue

        h1, h2 = _html(src, 1), _html(src, 2)

        t1 = _norm(_answer_text_from_html(h1))
        t2 = _norm(_answer_text_from_html(h2))
        a1 = _norm(row.get('answer_1'))
        a2 = _norm(row.get('answer_2'))

        direct = _ratio(t1, a1) + _ratio(t2, a2)
        swapped = _ratio(t1, a2) + _ratio(t2, a1)

        if swapped > direct and swapped >= 2 * _MATCH_MIN:
            # был шафл: в in1 ответы идут в обратном порядке — выравниваем под сорсы in3
            h1, h2 = h2, h1
            swapped_cnt += 1
        elif max(direct, swapped) < 2 * _MATCH_MIN:
            # ни один порядок не сошёлся по тексту: оставляем как есть, но пишем в лог,
            # иначе перепутанная пара молча уедет в разметку
            unverified += 1
            print('rownum=%s: html не сопоставился с текстом ответа '
                  '(direct=%.2f, swapped=%.2f)' % (key, direct, swapped))

        out['answer_1_html'] = h1
        out['answer_2_html'] = h2
        result.append(out)

    print('строк: %d, без пары в in1: %d, переставлено: %d, не сверено: %d'
          % (total, no_pair, swapped_cnt, unverified))
    return result
