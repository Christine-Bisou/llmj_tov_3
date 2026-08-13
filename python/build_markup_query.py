import json


def main(in1, in2=None, in3=None, mr_tables=None,
         token1=None, token2=None, param1=None, param2=None, html_file=None):

    # ===== FIX: корректная обработка in2 =====
    # in2 может приходить в разных форматах: list / json string / dict
    # WARNING: возможен неожиданный тип или пустой список
    if isinstance(in2, list):
        if len(in2) > 0:
            config_raw = in2[0]
        else:
            config_raw = "{}"
    else:
        config_raw = in2

    # WARNING: config_raw может быть невалидным JSON
    if isinstance(config_raw, (dict, list)):
        config = config_raw
    else:
        try:
            config = json.loads(config_raw)
        except Exception as e:
            return [{"query": "config_error: " + str(e), "good_data1": False}]
    # ===== END FIX =====

    # достаем основные словари из конфига
    # WARNING: ключи могут отсутствовать
    TERMS_DICT = config.get("TERMS_DICT", {})
    T = config.get("templates", {})
    DICT_BY_BRACKETS = config.get("dict_by_brackets", {})

    # функция: гарантирует, что вход — список
    def safe_list(x):
        if x is None:
            return []
        return x if isinstance(x, list) else [x]

    # функция: получить отмеченные чекбоксы для i-го редактора
    def get_checked_boxes(checkboxes, i):
        res = []
        for k, v in checkboxes.items():
            # WARNING: v может быть не списком или иметь меньшую длину
            if isinstance(v, list) and i < len(v) and v[i] is True:
                res.append(k)
        return res

    # функция: форматирование спанов (выделенных частей текста)
    def format_spans(marker_parts, i):
        res = []
        # WARNING: marker_parts может быть не списком
        if not isinstance(marker_parts, list):
            return res
        if i >= len(marker_parts):
            return res

        spans = marker_parts[i]
        # WARNING: spans может быть не списком
        if not isinstance(spans, list):
            return res

        for j, span in enumerate(spans):
            # WARNING: span может быть не dict
            if not isinstance(span, dict):
                continue
            line = T.get("span_line", "{content}").format(
                j=j+1,
                content=span.get("content", ""),
                i=i+1,
                type=DICT_BY_BRACKETS.get(span.get("type", ""), span.get("type", ""))
            )
            comment = span.get("comment", "")
            if comment:
                line += T.get("span_comment", "{comment}").format(comment=comment)
            res.append(line)
        return res

    # функция: агрегирует итоговый вердикт по списку решений редакторов
    def aggregate_verdicts(verdicts):
        count_A = count_B = count_D = count_BB = 0

        for v in verdicts:
            # Поддерживаем оба формата нейминга (model_A/B или model_1/2)
            if v in ("model_A", "model_1"):
                count_A += 1
            elif v in ("model_B", "model_2"):
                count_B += 1
            elif v == "draw":
                count_D += 1
            elif v == "both_bad":
                count_BB += 1

        n = len(verdicts)
        if n == 0:
            return "нет данных"

        # 1. Проверка абсолютного большинства (строго больше 50% голосов)
        if count_A * 2 > n:
            return "победила модель A"
        if count_B * 2 > n:
            return "победила модель B"
        if count_D * 2 > n:
            return "ничья"
        if count_BB * 2 > n:
            return "оба ответа плохие"

        # 2. Если абсолютного большинства нет, разбираем спорные случаи
        if n == 2:
            # 1 голос за модель перевешивает 1 голос за ничью или "оба хуже"
            if count_A == 1 and (count_D == 1 or count_BB == 1):
                return "победила модель A"
            if count_B == 1 and (count_D == 1 or count_BB == 1):
                return "победила модель B"

            # Конфликт моделей (A vs B)
            if count_A == 1 and count_B == 1:
                return "ничья"

            # Конфликт ничьей и "оба хуже"
            if count_D == 1 and count_BB == 1:
                return "оба ответа плохие"

        if n == 3:
            # Сюда мы попадаем только если счет 1-1-1 (ни у кого нет большинства).
            # По таблице: присутствие both_bad в таких тройках тянет итог в "оба ответа плохие"
            # (например: model_1(1) + draw(1) + both_bad(1) -> both_bad)
            if count_BB > 0:
                return "оба ответа плохие"

            # Если both_bad нет, но есть draw (например: model_1(1) + model_2(1) + draw(1) -> draw)
            if count_D > 0:
                return "ничья"

        # Общий fallback
        return "ничья"

    # приводим вход к списку строк
    data = safe_list(in1)
    out = []

    # основной цикл по строкам таблицы
    for row in data:
        if not isinstance(row, dict):
            continue

        errors = []

        new_row = dict(row)

        # ===== VALIDATION BLOCK =====
        # WARNING: проверка типов и структуры данных

        # Число разметчиков берем по списку worker_ids: колонки task_count
        # в таблице больше нет, а размечавших ровно столько, сколько записей.
        worker_ids = row.get("worker_ids", [])
        if not isinstance(worker_ids, list):
            errors.append(("worker_ids", worker_ids))
            worker_ids = []
        task_count = len(worker_ids)

        skip = row.get("skip", [])
        if not isinstance(skip, list):
            errors.append(("skip", skip))

        winners = row.get("source_winner", [])
        if not isinstance(winners, list):
            errors.append(("source_winner", winners))

        diff_pa = row.get("diff_pa", [])
        diff_pa_winner = row.get("diff_pa_winner", [])

        if not isinstance(diff_pa, list):
            errors.append(("diff_pa", diff_pa))

        if not isinstance(diff_pa_winner, list):
            errors.append(("diff_pa_winner", diff_pa_winner))

        # WARNING: критичная проверка соответствия размеров.
        # Все поразметчиковые списки идут по элементу на разметчика и в одном
        # порядке, поэтому сверяем длину с task_count. Раньше diff_pa_winner
        # приходил отфильтрованным по непустым, и сверка была с числом
        # отметивших проактивность.
        for key in ["skip", "source_winner", "diff_pa", "diff_pa_winner"]:
            val = row.get(key, [])
            if isinstance(val, list) and len(val) != task_count:
                errors.append((key + "_length", (len(val), task_count)))

        for key in ["checkboxes_A", "checkboxes_B"]:
            cb = row.get(key, {})
            if not isinstance(cb, dict):
                errors.append((key, cb))
        # ===== END VALIDATION =====

        # если нашли ошибки — возвращаем только их
        if errors:
            new_row["query"] = "\n".join([f"{k}: {v}" for k, v in errors])
            new_row["good_data1"] = False
            out.append(new_row)
            continue

        new_row["good_data1"] = True

        # ===== ОСНОВНАЯ ЛОГИКА =====

        # собираем все использованные термины
        used_terms = set()
        for i in range(task_count):
            if i < len(skip) and skip[i] is True:
                continue
            used_terms.update(get_checked_boxes(row.get("checkboxes_A", {}), i))
            used_terms.update(get_checked_boxes(row.get("checkboxes_B", {}), i))

        # фильтруем через словарь
        filtered_terms = [
            TERMS_DICT[k] for k in used_terms if k in TERMS_DICT
        ]

        query_parts = []

        # вступление
        query_parts.append(T.get("intro", ""))

        # словарь терминов
        if filtered_terms:
            query_parts.append(T.get("dict_header", ""))
            query_parts.extend(filtered_terms)

        query_parts.append("\n")

        # ===== МОДЕЛЬ A =====
        query_parts.append(T.get("model_a_header", "{answer}").format(answer=row.get("answer_A", "")))

        # чекбоксы A
        for i in range(task_count):
            if i < len(skip) and skip[i] is True:
                val = ""
            else:
                checked = get_checked_boxes(row.get("checkboxes_A", {}), i)
                val = ", ".join('"' + DICT_BY_BRACKETS.get(k, k) + '"' for k in checked) if checked else T.get("no_checkboxes", "")
            query_parts.append(T.get("checkbox_A", "{val}").format(i=i+1, val=val))

        query_parts.append("\n")

        # спаны A
        for i in range(task_count):
            query_parts.append(T.get("spans_A_header", "").format(i=i+1))
            if i < len(skip) and skip[i] is True:
                query_parts.append(T.get("no_spans", ""))
            else:
                spans = format_spans(row.get("marker_text_parts_A", []), i)
                query_parts.extend(spans if spans else [T.get("no_spans", "")])

        query_parts.append("\n")

        # комментарии A
        comments_A = row.get("comments_A", [])
        for i in range(task_count):
            if i < len(skip) and skip[i] is True:
                query_parts.append(T.get("comment_A", "{val}").format(i=i+1, val=""))
            elif i < len(comments_A) and comments_A[i]:
                query_parts.append(T.get("comment_A", "{val}").format(i=i+1, val=comments_A[i]))
            else:
                query_parts.append(T.get("no_comment", "").format(i=i+1))

        query_parts.append("\n")

        # ===== МОДЕЛЬ B =====
        query_parts.append(T.get("model_b_header", "{answer}").format(answer=row.get("answer_B", "")))
        query_parts.append("\n")

        # чекбоксы B
        for i in range(task_count):
            if i < len(skip) and skip[i] is True:
                val = ""
            else:
                checked = get_checked_boxes(row.get("checkboxes_B", {}), i)
                val = ", ".join('"' + DICT_BY_BRACKETS.get(k, k) + '"' for k in checked) if checked else T.get("no_checkboxes", "")
            query_parts.append(T.get("checkbox_B", "{val}").format(i=i+1, val=val))

        query_parts.append("\n")

        # спаны B
        for i in range(task_count):
            query_parts.append(T.get("spans_B_header", "").format(i=i+1))
            if i < len(skip) and skip[i] is True:
                query_parts.append(T.get("no_spans", ""))
            else:
                spans = format_spans(row.get("marker_text_parts_B", []), i)
                query_parts.extend(spans if spans else [T.get("no_spans", "")])

        query_parts.append("\n")

        # комментарии B
        comments_B = row.get("comments_B", [])
        for i in range(task_count):
            if i < len(skip) and skip[i] is True:
                query_parts.append(T.get("comment_B", "{val}").format(i=i+1, val=""))
            elif i < len(comments_B) and comments_B[i]:
                query_parts.append(T.get("comment_B", "{val}").format(i=i+1, val=comments_B[i]))
            else:
                query_parts.append(T.get("no_comment", "").format(i=i+1))

        query_parts.append("\n")

        # общие комментарии
        general_comments = row.get("general_comments", [])
        for i in range(task_count):
            if i < len(skip) and skip[i] is True:
                val = ""
            else:
                val = general_comments[i] if i < len(general_comments) else ""
            query_parts.append(T.get("general_comment", "{val}").format(i=i+1, val=val))

        query_parts.append("\n")

        # ===== ВЕРДИКТЫ =====
        source_A = row.get("source_A")
        source_B = row.get("source_B")
        winners = row.get("source_winner", [])

        verdicts_with_pa = []
        verdict_lines_with_pa = []

        # формируем вердикты с учетом проактивности
        for i in range(task_count):
            if i < len(skip) and skip[i] is True:
                verdict_lines_with_pa.append(T.get("winner_skip", "").format(i=i+1))
                continue

            w = winners[i] if i < len(winners) else None

            if w == source_A:
                verdicts_with_pa.append("model_A")
                verdict_lines_with_pa.append(T.get("winner_A", "").format(i=i+1))
            elif w == source_B:
                verdicts_with_pa.append("model_B")
                verdict_lines_with_pa.append(T.get("winner_B", "").format(i=i+1))
            elif w == "draw":
                verdicts_with_pa.append("draw")
                verdict_lines_with_pa.append(T.get("winner_draw", "").format(i=i+1))
            elif w == "both_bad":
                verdicts_with_pa.append("both_bad")
                verdict_lines_with_pa.append(T.get("winner_both_bad", "").format(i=i+1))
            else:
                verdicts_with_pa.append("unknown")
                verdict_lines_with_pa.append(T.get("winner_unknown", "Unknown winner").format(i=i+1))

        # пересчет без учета проактивности
        diff_pa = row.get("diff_pa", [])
        diff_pa_winner = row.get("diff_pa_winner", [])

        verdicts_without_pa = verdicts_with_pa[:]

        # diff_pa_winner идет по элементу на разметчика, поэтому берем его по
        # тому же индексу, что и остальное. У неотметившего там "null" —
        # такое значение вердикт не меняет.
        idx = 0
        for i in range(task_count):
            if i < len(skip) and skip[i] is True:
                continue
            if i < len(diff_pa) and diff_pa[i] is True:
                val = diff_pa_winner[i] if i < len(diff_pa_winner) else None

                if val == source_A:
                    verdicts_without_pa[idx] = "model_A"
                elif val == source_B:
                    verdicts_without_pa[idx] = "model_B"
                elif val == "draw":
                    verdicts_without_pa[idx] = "draw"
                elif val == "both_bad":
                    verdicts_without_pa[idx] = "both_bad"
                # иначе оставляем вердикт с учетом проактивности как есть
            idx += 1

        final_with_pa = aggregate_verdicts(verdicts_with_pa)
        final_without_pa = aggregate_verdicts(verdicts_without_pa)

        # финальный блок текста
        if any(v is True for v in diff_pa):

            query_parts.append(T.get("final_with_pa_header", ""))
            query_parts.extend(verdict_lines_with_pa)
            query_parts.append(T.get("final_with_pa", "{val}").format(val=final_with_pa))

            query_parts.append(T.get("final_without_pa_header", ""))

            verdict_lines_without_pa = []
            idx = 0
            for i in range(task_count):
                if i < len(skip) and skip[i] is True:
                    verdict_lines_without_pa.append(T.get("winner_skip", "").format(i=i+1))
                    continue

                v = verdicts_without_pa[idx]
                if v == "model_A":
                    verdict_lines_without_pa.append(T.get("winner_A", "").format(i=i+1))
                elif v == "model_B":
                    verdict_lines_without_pa.append(T.get("winner_B", "").format(i=i+1))
                elif v == "draw":
                    verdict_lines_without_pa.append(T.get("winner_draw", "").format(i=i+1))
                elif v == "both_bad":
                    verdict_lines_without_pa.append(T.get("winner_both_bad", "").format(i=i+1))
                else:
                    verdict_lines_without_pa.append(T.get("winner_unknown", "Unknown winner").format(i=i+1))
                idx += 1

            query_parts.extend(verdict_lines_without_pa)
            query_parts.append(T.get("final_without_pa", "{val}").format(val=final_without_pa))

            query_parts.append(T.get("final_instruction_diff", ""))

        else:
            query_parts.append(T.get("final_with_pa_header", ""))
            query_parts.extend(verdict_lines_with_pa)
            query_parts.append(T.get("final_same", ""))
            query_parts.append(T.get("final_with_pa", "{val}").format(val=final_with_pa))
            query_parts.append(T.get("final_instruction", ""))

        query_parts.append("\nВ своем ответе используй истинные имена моделей, а не лейблы A и B. Делай согласно соответствию в этом словаре:\n")

        # ---- 4. Хелпер: красивая сериализация для системного промпта ----
        def to_json_block(obj, compact=False):
            if isinstance(obj, str):
                try:
                    obj = json.loads(obj)
                except Exception:
                    return obj
            if compact:
                return json.dumps(obj, ensure_ascii=False, separators=(",", ":"))
            return json.dumps(obj, ensure_ascii=False, indent=2)

        source_A = row.get("source_A", "")
        source_B = row.get("source_B", "")

        model_labels = {"A": source_A, "B": source_B}

        query_parts.append(to_json_block(model_labels))

        # формируем ссылки на задания
        assignment_ids = row.get("assignment_ids", [])
        pool_id = row.get("pool_id", "")
        assignments_links = []
        for i in range(len(assignment_ids)):
            assignments_links.append("https://yang.yandex-team.ru/task/" + str(pool_id) + "/" + str(assignment_ids[i]))
        new_row["assignments_links"] = assignments_links

        # финальный query
        new_row["query"] = "\n".join(query_parts)
        out.append(new_row)

    return out
