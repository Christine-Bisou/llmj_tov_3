# -*- coding: utf-8 -*-
"""Приклеивает html-рендеры ответов к таблице разметки.

in1 — таблица с отрендеренными ответами (answer_1 / answer_2 — html);
in3 — таблица разметки, склейка по rownum.

Всё из in3 переносится как есть, добавляются answer_1_html и answer_2_html.
Если продюсер первого ответа в in1 не совпал с answer_source_1 из in3 — значит
был шафл, и html-колонки меняются местами.
"""


def _producer(rec, i):
    """Имя модели i-го ответа в in1 (0 или 1)."""
    answers = rec.get('answers') or []
    if i < len(answers):
        producer = answers[i].get('answer_producer')
        if isinstance(producer, dict):
            return producer.get('name')
        return producer
    return rec.get('answer_source_%d' % (i + 1))


def main(in1, in2, in3, mr_tables, token1=None, token2=None,
         param1=None, param2=None, html_file=None):
    by_rownum = {}
    for i, rec in enumerate(in1):
        by_rownum[rec.get('rownum', i)] = rec

    result = []
    for i, row in enumerate(in3):
        out = dict(row)
        src = by_rownum.get(row.get('rownum', i))

        if src is None:
            # строку не выкидываем: пусть в таблице видно, что html не доехал
            out['answer_1_html'] = None
            out['answer_2_html'] = None
        else:
            h1, h2 = src.get('answer_1'), src.get('answer_2')
            if _producer(src, 0) != row.get('answer_source_1'):
                h1, h2 = h2, h1
            out['answer_1_html'] = h1
            out['answer_2_html'] = h2

        result.append(out)

    return result
