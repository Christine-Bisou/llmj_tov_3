PRAGMA Yson.AutoConvert;
PRAGMA yson.DisableStrict;
PRAGMA SimpleColumns;
PRAGMA yt.UseNativeYtTypes;
PRAGMA AnsiInForEmptyOrNullableItemsCollections;
PRAGMA yt.InferSchema = '2';

DECLARE $input1 AS String;
DECLARE $input2 AS String;
DECLARE $output1 AS String;

-- Склейка прямого и обратного прохода второго этапа (v4: аудит + SbS).
--
-- $input1 — прямой прогон (answer_1 шёл первым), $input2 — обратный.
-- В обеих таблицах ответ джаджа лежит в dst.
--
-- СХЕМА ВХОДА (обе таблицы — сырой выход инференса, поверх исходного пула):
--   answer_1, answer_2, answer_source_1, answer_source_2,
--   clarity_1/2, liveliness_1/2, connect_1/2, overall_1/2, pointwise_1/2,
--   winner, comment, family_1/2, dialog, instruct, meta,
--   instruct_id, real_instruct_id,
--   markers_1_answer, markers_2_answer,
--   model_1_analysis, model_2_analysis,
--   model_1_linguistic_scan, model_2_linguistic_scan,
--   dst, reasoning_dst, parsed_ok, promt, infer_dialog
--
-- Отсюда два следствия, из-за которых запрос отличается от прошлой версии.
--
-- 1. Сорсов source_A / source_B в этой схеме нет — есть answer_source_1 и
--    answer_source_2. Ключ склейки и подстановка имени победителя идут по ним.
--
-- 2. Колонки clarity_1..overall_2, pointwise_1/2, winner, comment — это разметка,
--    которая лежала в пуле ДО инференса (инференс дописал только dst /
--    reasoning_dst / parsed_ok / promt / infer_dialog). Мы их не трогаем: по ним
--    считается согласие джаджа с разметкой, и перезаписать их значит потерять
--    вторую сторону сравнения. Поэтому то, что считает этот запрос, живёт под
--    своими именами: tov_pointwise_1/2, clc_metrics_1/2, tov_winner_source.
--
-- Что на выходе:
--   tov_pointwise_1 / tov_pointwise_2 — звёзды по трём аспектам + общая, с
--                               разбивкой по проходам и усреднением;
--   markers_1 / markers_2     — словарь 13 маркеров после аудита, с пометкой,
--                               в каком проходе маркер сработал;
--   sbs                       — вердикт с обоих проходов, сразу в сорсах.

$script = @@#py
import json
import cyson


def process_json(s):
    """
    (String?) -> Yson?
    """
    if s is None:
        return None

    if isinstance(s, bytes):
        s = s.decode('utf-8', errors='ignore')
    else:
        s = str(s)

    s = s.strip()
    if s.startswith('```json'):
        s = s[7:]
    elif s.startswith('```'):
        s = s[3:]
    if s.endswith('```'):
        s = s[:-3]
    s = s.strip()

    i, j = s.find('{'), s.rfind('}')
    if i != -1 and j != -1 and j > i:
        s = s[i:j + 1]

    try:
        return cyson.dumps(json.loads(s, strict=False))
    except Exception:
        return None
@@;

$process_json = Python3::process_json($script);

$marker_names = AsList(
    'empathy', 'subjectivity', 'tone_match', 'humor_metaphors', 'critical_tone',
    'bad_intro', 'bad_proactivity', 'over_emotional', 'stuffy_bureaucratic',
    'boundaries_violation', 'template_phrases', 'language_errors', 'inconsistency'
);

-- ========================= ЗВЁЗДЫ =========================
-- ConvertToDouble вместо LookupInt64: переживёт и 4, и 4.0, и "4".
$score = ($node, $model, $asp) -> {
    RETURN Yson::ConvertToDouble(
        Yson::Lookup(Yson::Lookup(Yson::Lookup($node, $model), $asp), 'score')
    ) ?? 0.0;
};

$reason = ($node, $model, $asp) -> {
    RETURN Yson::LookupString(
        Yson::Lookup(Yson::Lookup($node, $model), $asp), 'reasoning'
    ) ?? '';
};

$avg = ($dir, $rev, $md, $mr, $asp) -> {
    RETURN ($score($dir, $md, $asp) + $score($rev, $mr, $asp)) / 2.0;
};

-- Итоговая звезда: среднее двух проходов, округлённое ВНИЗ (4 и 5 -> 4.5 -> 4).
$star = ($dir, $rev, $md, $mr, $asp) -> {
    RETURN CAST(Math::Floor($avg($dir, $rev, $md, $mr, $asp)) AS Int64);
};

$aspect_block = ($dir, $rev, $md, $mr, $asp) -> {
    RETURN <|
        score:     $star($dir, $rev, $md, $mr, $asp),
        avg:       $avg($dir, $rev, $md, $mr, $asp),
        direct:    $score($dir, $md, $asp),
        reversed:  $score($rev, $mr, $asp),
        reasoning: $reason($dir, $md, $asp)
    |>;
};

-- $md — ключ этого ответа в прямом проходе, $mr — в обратном (там всё зеркально).
$pointwise = ($dir, $rev, $md, $mr) -> {
    RETURN Just(Yson::From(<|
        clarity:    $aspect_block($dir, $rev, $md, $mr, 'clarity'),
        liveliness: $aspect_block($dir, $rev, $md, $mr, 'liveliness'),
        connect:    $aspect_block($dir, $rev, $md, $mr, 'connect'),
        overall:    $aspect_block($dir, $rev, $md, $mr, 'overall')
    |>));
};

-- Четыре числа без обвязки — формат разметки.
$clc = ($dir, $rev, $md, $mr) -> {
    RETURN Just(Yson::From(<|
        clarity:    $star($dir, $rev, $md, $mr, 'clarity'),
        liveliness: $star($dir, $rev, $md, $mr, 'liveliness'),
        connect:    $star($dir, $rev, $md, $mr, 'connect'),
        overall:    $star($dir, $rev, $md, $mr, 'overall')
    |>));
};

-- ========================= МАРКЕРЫ =========================
-- v4 отдаёт разметку после аудита: model_N_markers_review.markers.
-- Это НЕ то же самое, что markers_1_answer / markers_2_answer во входе: там
-- лежит вход первого этапа, который джадж и пересматривал. Обе колонки нужны,
-- поэтому имена разные.
$mk = ($node, $review_key) -> {
    RETURN Yson::Lookup(Yson::Lookup($node, $review_key), 'markers');
};

$is_on = ($mk_node, $name) -> {
    RETURN Yson::ConvertToBool(
        Yson::Lookup(Yson::Lookup($mk_node, $name), 'is_present')
    ) ?? false;
};

$why = ($mk_node, $name) -> {
    RETURN Yson::LookupString(Yson::Lookup($mk_node, $name), 'explanation') ?? '';
};

$audit = ($mk_node, $name) -> {
    RETURN Yson::LookupString(Yson::Lookup($mk_node, $name), 'audit') ?? '';
};

-- Маркер считаем выставленным, если его увидел ХОТЯ БЫ один проход:
-- пропуск маркера — настоящая ошибка, лишнее срабатывание видно по in_direct /
-- in_reversed и по agreed, так что объединение ничего не прячет.
$markers = ($d_mk, $r_mk) -> {
    RETURN Just(Yson::From(ToDict(ListMap($marker_names, ($n) -> {
        RETURN AsTuple($n, <|
            is_present:  $is_on($d_mk, $n) OR $is_on($r_mk, $n),
            in_direct:   $is_on($d_mk, $n),
            in_reversed: $is_on($r_mk, $n),
            agreed:      $is_on($d_mk, $n) == $is_on($r_mk, $n),
            audit:       IF($audit($d_mk, $n) != '', $audit($d_mk, $n), $audit($r_mk, $n)),
            explanation: IF($is_on($d_mk, $n), $why($d_mk, $n), $why($r_mk, $n))
        |>);
    }))));
};

-- Только флаги, без пояснений — для метрик и джойнов с золотом.
$marker_flags = ($d_mk, $r_mk) -> {
    RETURN Just(Yson::From(ToDict(ListMap($marker_names, ($n) -> {
        RETURN AsTuple($n, $is_on($d_mk, $n) OR $is_on($r_mk, $n));
    }))));
};

$marker_list = ($d_mk, $r_mk) -> {
    RETURN ListFilter($marker_names, ($n) -> {
        RETURN $is_on($d_mk, $n) OR $is_on($r_mk, $n);
    });
};

-- Доля маркеров, по которым проходы сошлись: низкая — повод посмотреть строку руками.
$marker_agreement = ($d_mk, $r_mk) -> {
    RETURN CAST(ListLength(ListFilter($marker_names, ($n) -> {
        RETURN $is_on($d_mk, $n) == $is_on($r_mk, $n);
    })) AS Double) / CAST(ListLength($marker_names) AS Double);
};

-- ========================= ВЕРДИКТ =========================
$verdict = ($node) -> {
    RETURN Yson::LookupString(Yson::Lookup($node, 'sbs_comparison'), 'verdict') ?? 'tie';
};

$sbs_why = ($node) -> {
    RETURN Yson::LookupString(Yson::Lookup($node, 'sbs_comparison'), 'reasoning') ?? '';
};

-- В обратном проходе model_1 — это answer_2, поэтому вердикт зеркалим.
$flip = ($v) -> {
    RETURN CASE WHEN $v = 'model_1' THEN 'model_2'
                WHEN $v = 'model_2' THEN 'model_1'
                ELSE 'tie' END;
};

-- Победитель сразу сорсом, а не «model_1»: имя модели читается без сверки с таблицей.
-- 'tie' и 'conflict' пробрасываем как есть: подменять их на 'tie' нельзя,
-- иначе несогласие проходов растворится в честных ничьих.
$as_source = ($w, $s1, $s2) -> {
    RETURN CASE $w
        WHEN 'model_1' THEN COALESCE(CAST($s1 AS String), 'model_1')
        WHEN 'model_2' THEN COALESCE(CAST($s2 AS String), 'model_2')
        ELSE COALESCE($w, 'tie')
    END;
};

-- ========================= КЛЮЧ СКЛЕЙКИ =========================
-- Почему были задвоения: instruct_id — это идентификатор ЗАДАНИЯ, а не строки.
-- По одному instruct_id в таблице лежит столько строк, сколько по нему было пар
-- (и перезапусков). JOIN USING (instruct_id) даёт декартово произведение:
-- 3 строки слева × 3 справа = 9 вместо 3, и звёзды answer_1 из одной пары
-- склеиваются с вердиктом из другой.
--
-- Чиним в два шага:
--   1) ключом делаем instruct_id + саму пару ответов;
--   2) каждую сторону схлопываем до одной строки на ключ, так что джойн
--      становится строго 1:1 и размножить строки больше нечем.
--
-- Пара берётся из answer_source_1 / answer_source_2 и НЕУПОРЯДОЧЕННОЙ (min/max):
-- в обратном прогоне ответы переставлены, и упорядоченный ключ (A,B) не нашёл
-- бы там (B,A). Неупорядоченный ключ одинаков при любой перестановке, поэтому
-- он сойдётся и если обратная таблица меняет сорсы местами, и если оставляет
-- их как есть.
-- Единственный случай, где ключ склеит лишнее, — если по одному instruct_id
-- сравниваются обе перестановки одной и той же пары как разные задания;
-- в таком раскладе ключ надо расширять полем порядка.
--
-- Если в каком-то прогоне сорсы не проставлены, соберите ключ из самих ответов:
-- Digest::Md5Hex(CAST(answer_1 AS String)), логика ниже не меняется.
$pair_key = ($id, $s1, $s2) -> {
    $a = COALESCE(CAST($s1 AS String), '');
    $b = COALESCE(CAST($s2 AS String), '');
    RETURN COALESCE(CAST($id AS String), '') || '\t'
        || IF($a <= $b, $a, $b) || '\t'
        || IF($a <= $b, $b, $a);
};

$keyed_direct = (
    SELECT
        i.*,
        $pair_key(i.instruct_id, i.answer_source_1, i.answer_source_2) AS pair_key
    FROM $input1 AS i
);

$keyed_reversed = (
    SELECT
        i.instruct_id                                                  AS instruct_id,
        i.dst                                                          AS dst,
        $pair_key(i.instruct_id, i.answer_source_1, i.answer_source_2) AS pair_key
    FROM $input2 AS i
);

-- Схлопывание дублей внутри одного прохода. Порядок по ответу джаджа, а не по
-- номеру строки: выбор не поедет при перезапуске операции.
$ranked_direct = (
    SELECT
        k.*,
        ROW_NUMBER() OVER (PARTITION BY pair_key ORDER BY CAST(dst AS String)) AS rn
    FROM $keyed_direct AS k
);

$ranked_reversed = (
    SELECT
        k.*,
        ROW_NUMBER() OVER (PARTITION BY pair_key ORDER BY CAST(dst AS String)) AS rn
    FROM $keyed_reversed AS k
);

$direct = (
    SELECT r.* WITHOUT r.rn FROM $ranked_direct   AS r WHERE r.rn == 1
);

$reversed = (
    SELECT r.* WITHOUT r.rn FROM $ranked_reversed AS r WHERE r.rn == 1
);

-- ========================= РАЗБОР =========================
-- 1:1 по (instruct_id, пара). INNER — строка без своей половины из второго
-- прохода в выход не идёт: считать по ней среднее не из чего.
$parsed = (
    SELECT
        i1.*,
        $process_json(CAST(i1.dst AS String)) AS dir_yson,
        $process_json(CAST(i2.dst AS String)) AS rev_yson
    FROM $direct AS i1
    INNER JOIN $reversed AS i2
    ON i1.pair_key == i2.pair_key
);

$calc = (
    SELECT
        $verdict(dir_yson)          AS w_direct,
        $flip($verdict(rev_yson))   AS w_reversed_norm,

        $mk(dir_yson, 'model_1_markers_review') AS mk1_dir,
        $mk(dir_yson, 'model_2_markers_review') AS mk2_dir,
        -- в обратном проходе разметка answer_1 лежит под model_2 — и наоборот
        $mk(rev_yson, 'model_2_markers_review') AS mk1_rev,
        $mk(rev_yson, 'model_1_markers_review') AS mk2_rev,

        -- parsed_ok во входе — про сам инференс (ответ джаджа вообще пришёл).
        -- Здесь другое: удалось ли разобрать JSON обоих проходов. Если нет,
        -- Yson::Lookup молча вернёт NULL и все звёзды станут нулями, поэтому
        -- флаг нужен отдельной колонкой, а не вместо parsed_ok.
        (dir_yson IS NOT NULL AND rev_yson IS NOT NULL) AS merge_parsed_ok,

        -- tov_winner мог остаться от прошлых склеек: снимаем, иначе алиас ниже
        -- упрётся в «Duplicated member». Звёздочка с WITHOUT — строго последняя
        -- в списке: после неё парсер ждёт только имена колонок.
        p.* WITHOUT IF EXISTS p.tov_winner
    FROM $parsed AS p
);

$final = (
    SELECT
        c.*,
        CASE
            WHEN w_direct = w_reversed_norm            THEN w_direct
            WHEN w_direct IN ('tie', 'draw')           THEN w_reversed_norm
            WHEN w_reversed_norm IN ('tie', 'draw')    THEN w_direct
            -- проходы назвали разных победителей: это не ничья по существу,
            -- а несогласие джаджа — помечаем отдельно, чтобы не мешать с tie
            ELSE 'conflict'
        END AS tov_winner
    FROM $calc AS c
);

INSERT INTO $output1 WITH TRUNCATE
SELECT
    -- ---------- звёзды ----------
    -- имена с префиксом tov_: pointwise_1 / pointwise_2 во входе — это разметка,
    -- и она должна доехать до выхода нетронутой, чтобы было с чем сравнивать
    $pointwise(f.dir_yson, f.rev_yson, 'model_1_evaluation', 'model_2_evaluation') AS tov_pointwise_1,
    $pointwise(f.dir_yson, f.rev_yson, 'model_2_evaluation', 'model_1_evaluation') AS tov_pointwise_2,
    $clc(f.dir_yson, f.rev_yson, 'model_1_evaluation', 'model_2_evaluation')       AS clc_metrics_1,
    $clc(f.dir_yson, f.rev_yson, 'model_2_evaluation', 'model_1_evaluation')       AS clc_metrics_2,

    -- ---------- маркеры ----------
    $markers(f.mk1_dir, f.mk1_rev)           AS markers_1,
    $markers(f.mk2_dir, f.mk2_rev)           AS markers_2,
    $marker_flags(f.mk1_dir, f.mk1_rev)      AS markers_1_flags,
    $marker_flags(f.mk2_dir, f.mk2_rev)      AS markers_2_flags,
    $marker_list(f.mk1_dir, f.mk1_rev)       AS markers_1_list,
    $marker_list(f.mk2_dir, f.mk2_rev)       AS markers_2_list,
    $marker_agreement(f.mk1_dir, f.mk1_rev)  AS markers_1_agreement,
    $marker_agreement(f.mk2_dir, f.mk2_rev)  AS markers_2_agreement,

    -- ---------- вердикт ----------
    Just(Yson::From(<|
        winner:            $as_source(f.tov_winner, f.answer_source_1, f.answer_source_2),
        winner_model:      f.tov_winner,
        direct:            $as_source(f.w_direct, f.answer_source_1, f.answer_source_2),
        reversed:          $as_source(f.w_reversed_norm, f.answer_source_1, f.answer_source_2),
        agreement:         IF(f.w_direct = f.w_reversed_norm, 1.0, 0.0),
        strength:          IF(f.w_direct = f.w_reversed_norm, 'strong', 'weak'),
        reasoning_direct:  $sbs_why(f.dir_yson),
        reasoning_reversed: $sbs_why(f.rev_yson)
    |>))                                     AS sbs,

    -- плоско, чтобы фильтровать и группировать без Yson::Lookup.
    -- winner во входе — колонка разметки, её не трогаем: вердикт джаджа
    -- отдельными tov_winner / tov_winner_source, сравнение — джойном.
    $as_source(f.tov_winner, f.answer_source_1, f.answer_source_2) AS tov_winner_source,

    Just(Yson::From(<|
        model_winner_direct:              f.w_direct,
        model_winner_reversed_normalized: f.w_reversed_norm,
        reasoning_direct:                 $sbs_why(f.dir_yson),
        reasoning_reversed:               $sbs_why(f.rev_yson),
        direct_m1_overall:                $score(f.dir_yson, 'model_1_evaluation', 'overall'),
        direct_m2_overall:                $score(f.dir_yson, 'model_2_evaluation', 'overall'),
        reversed_m1_overall:              $score(f.rev_yson, 'model_2_evaluation', 'overall'),
        reversed_m2_overall:              $score(f.rev_yson, 'model_1_evaluation', 'overall'),
        process_url:                      'https://nirvana.yandex-team.ru/process/9113ab38-0999-4125-b182-523e63252411',
        graph_owner:                      'kristisha'
    |>))                                     AS meta_info,

    -- WITHOUT обязан быть последним элементом списка.
    -- Первый блок — служебное этого запроса, второй — тяжёлые колонки инференса:
    -- promt и infer_dialog это копия промпта в каждой строке, dst и reasoning_dst
    -- уже разобраны в колонки выше. Если нужен сырой ответ джаджа для разбора
    -- полётов — уберите dst и reasoning_dst из списка.
    -- Разметку (clarity_1..overall_2, pointwise_1/2, winner, comment) не снимаем
    -- намеренно: по ней считается согласие джаджа с людьми.
    f.* WITHOUT IF EXISTS
        f.dir_yson, f.rev_yson, f.pair_key,
        f.mk1_dir, f.mk2_dir, f.mk1_rev, f.mk2_rev,
        f.w_direct, f.w_reversed_norm,

        f.dst, f.reasoning_dst, f.infer_dialog, f.promt
FROM $final AS f;
