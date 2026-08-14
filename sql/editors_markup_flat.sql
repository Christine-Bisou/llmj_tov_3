PRAGMA AnsiInForEmptyOrNullableItemsCollections;
PRAGMA AnsiOptionalAs;
PRAGMA yt.UseNativeYtTypes;
PRAGMA yson.DisableStrict;

DECLARE $input1 AS String;
DECLARE $output1 AS String;

$str = ($x) -> (nvl(Yson::ConvertToString($x), ""));

$prep = (
    SELECT
        COALESCE(CAST(task_id AS String), "") AS task_id,
        $str(metadata.instruct_id) AS instruct_id,
        answer_A,
        answer_B,
        source_A,
        source_B,
        assignment_ids,
        metadata,
        markers,
        annotations,
        checkboxes,
        checkboxes_A,
        checkboxes_B,
        pointwise_A,
        pointwise_B,
        diff_pa,
        diff_pa_winner,
        direct_speech_A,
        direct_speech_B,
        general_comments,
        comments_A,
        comments_B,
        dialog,
        skip,
        source_winner,
        worker_ids,
        pool_id,
        ListFromRange(0u, CAST(ListLength(assignment_ids) AS Uint64)) AS idxs
    FROM $input1
    WHERE COALESCE(CAST(task_id AS String), "") != ""
);

$rows = (
    SELECT
        p.task_id AS task_id,
        p.source_A AS source_A,
        p.source_B AS source_B,
        p.idxs AS idx,
        CAST(COALESCE(p.source_winner[p.idxs], "") AS String) AS sw_raw,
        CAST(COALESCE(p.diff_pa_winner[p.idxs], "") AS String) AS dp_raw,
        COALESCE(p.skip[p.idxs], false) AS skip_vote,
        COALESCE(p.diff_pa[p.idxs], false) AS diff_pa_vote,
        COALESCE(p.direct_speech_A[p.idxs], false) AS dsA_vote,
        COALESCE(p.direct_speech_B[p.idxs], false) AS dsB_vote,
        p.checkboxes_A AS cbA_yson,
        p.checkboxes_B AS cbB_yson
    FROM $prep AS p
    FLATTEN LIST BY (idxs)
);

$rows_norm = (
    SELECT
        r.task_id AS task_id,
        r.source_A AS source_A,
        r.source_B AS source_B,
        r.idx AS idx,
        r.skip_vote AS skip_vote,
        r.diff_pa_vote AS diff_pa_vote,
        r.dsA_vote AS dsA_vote,
        r.dsB_vote AS dsB_vote,
        r.cbA_yson AS cbA_yson,
        r.cbB_yson AS cbB_yson,
        r.sw_raw AS sw_raw,
        r.dp_raw AS dp_raw,
        CASE
            WHEN r.diff_pa_vote
                 AND (r.dp_raw = r.source_A OR r.dp_raw = r.source_B OR r.dp_raw = "draw" OR r.dp_raw = "both_bad")
            THEN r.dp_raw
            ELSE r.sw_raw
        END AS dp_eff_raw
    FROM $rows AS r
);

/* CHECKBOXES A */
/* Маркера ясности больше не существует, поэтому tov_plus_clarity здесь нет.
   Ключ приходить перестал, а разворачивание идёт по фиксированному списку —
   так что колонка иначе была бы вечным false. */

$cbA_from_dict_bool = (
    SELECT
        rn.task_id AS task_id,
        CAST(item.0 AS String) AS cb_key,
        COALESCE(item.1, false) AS cb_val
    FROM (
        SELECT
            task_id,
            Yson::ConvertTo(
                cbA_yson,
                Dict<String, Bool>,
                Yson::Options(false AS Strict)
            ) AS cb_dict
        FROM $rows_norm
        WHERE cbA_yson IS NOT NULL AND NOT Yson::IsList(cbA_yson)
    ) AS rn
    FLATTEN DICT BY cb_dict AS item
);

$cbA_from_dict_indexed = (
    SELECT
        rn.task_id AS task_id,
        CAST(item.0 AS String) AS cb_key,
        COALESCE(item.1[rn.idx], false) AS cb_val
    FROM (
        SELECT
            task_id,
            idx,
            Yson::ConvertTo(
                cbA_yson,
                Dict<String, List<Bool>>,
                Yson::Options(false AS Strict)
            ) AS cb_dict
        FROM $rows_norm
        WHERE cbA_yson IS NOT NULL AND NOT Yson::IsList(cbA_yson)
    ) AS rn
    FLATTEN DICT BY cb_dict AS item
    WHERE CAST(ListLength(item.1) AS Uint64) > rn.idx
);

$cbA_norm = (
    SELECT * FROM $cbA_from_dict_bool
    UNION ALL
    SELECT * FROM $cbA_from_dict_indexed
);

$cbA_key = (
    SELECT
        n.task_id AS task_id,
        n.cb_key AS cb_key,
        MAX(CAST(n.cb_val AS Uint8)) > 0 AS cb_or
    FROM $cbA_norm AS n
    GROUP BY n.task_id, n.cb_key
);

$cbA_instr = (
    SELECT
        k.task_id AS task_id,
        MAX(CASE WHEN k.cb_key = "point_bad_intro" THEN CAST(k.cb_or AS Uint8) ELSE CAST(0 AS Uint8) END) > 0 AS point_bad_intro,
        MAX(CASE WHEN k.cb_key = "point_bad_proactivity" THEN CAST(k.cb_or AS Uint8) ELSE CAST(0 AS Uint8) END) > 0 AS point_bad_proactivity,
        MAX(CASE WHEN k.cb_key = "tov_minus_addressing" THEN CAST(k.cb_or AS Uint8) ELSE CAST(0 AS Uint8) END) > 0 AS tov_minus_addressing,
        MAX(CASE WHEN k.cb_key = "tov_minus_boundary_violation" THEN CAST(k.cb_or AS Uint8) ELSE CAST(0 AS Uint8) END) > 0 AS tov_minus_boundary_violation,
        MAX(CASE WHEN k.cb_key = "tov_minus_cliches" THEN CAST(k.cb_or AS Uint8) ELSE CAST(0 AS Uint8) END) > 0 AS tov_minus_cliches,
        MAX(CASE WHEN k.cb_key = "tov_minus_dry" THEN CAST(k.cb_or AS Uint8) ELSE CAST(0 AS Uint8) END) > 0 AS tov_minus_dry,
        MAX(CASE WHEN k.cb_key = "tov_minus_language_errors" THEN CAST(k.cb_or AS Uint8) ELSE CAST(0 AS Uint8) END) > 0 AS tov_minus_language_errors,
        MAX(CASE WHEN k.cb_key = "tov_minus_overemotional" THEN CAST(k.cb_or AS Uint8) ELSE CAST(0 AS Uint8) END) > 0 AS tov_minus_overemotional,
        MAX(CASE WHEN k.cb_key = "tov_plus_empathy" THEN CAST(k.cb_or AS Uint8) ELSE CAST(0 AS Uint8) END) > 0 AS tov_plus_empathy,
        MAX(CASE WHEN k.cb_key = "tov_plus_humor" THEN CAST(k.cb_or AS Uint8) ELSE CAST(0 AS Uint8) END) > 0 AS tov_plus_humor,
        MAX(CASE WHEN k.cb_key = "tov_plus_subject" THEN CAST(k.cb_or AS Uint8) ELSE CAST(0 AS Uint8) END) > 0 AS tov_plus_subject,
        MAX(CASE WHEN k.cb_key = "tov_plus_tone_match" THEN CAST(k.cb_or AS Uint8) ELSE CAST(0 AS Uint8) END) > 0 AS tov_plus_tone_match,
        MAX(CASE WHEN k.cb_key = "tov_tone_unacceptable" THEN CAST(k.cb_or AS Uint8) ELSE CAST(0 AS Uint8) END) > 0 AS tov_tone_unacceptable
    FROM $cbA_key AS k
    GROUP BY k.task_id
);

$cbA_false_instr = (
    SELECT
        k.task_id AS task_id,
        false AS point_bad_intro,
        false AS point_bad_proactivity,
        false AS tov_minus_addressing,
        false AS tov_minus_boundary_violation,
        false AS tov_minus_cliches,
        false AS tov_minus_dry,
        false AS tov_minus_language_errors,
        false AS tov_minus_overemotional,
        false AS tov_plus_empathy,
        false AS tov_plus_humor,
        false AS tov_plus_subject,
        false AS tov_plus_tone_match,
        false AS tov_tone_unacceptable
    FROM $cbA_key AS k
    GROUP BY k.task_id
);

/* CHECKBOXES B */

$cbB_from_dict_bool = (
    SELECT
        rn.task_id AS task_id,
        CAST(item.0 AS String) AS cb_key,
        COALESCE(item.1, false) AS cb_val
    FROM (
        SELECT
            task_id,
            Yson::ConvertTo(
                cbB_yson,
                Dict<String, Bool>,
                Yson::Options(false AS Strict)
            ) AS cb_dict
        FROM $rows_norm
        WHERE cbB_yson IS NOT NULL AND NOT Yson::IsList(cbB_yson)
    ) AS rn
    FLATTEN DICT BY cb_dict AS item
);

$cbB_from_dict_indexed = (
    SELECT
        rn.task_id AS task_id,
        CAST(item.0 AS String) AS cb_key,
        COALESCE(item.1[rn.idx], false) AS cb_val
    FROM (
        SELECT
            task_id,
            idx,
            Yson::ConvertTo(
                cbB_yson,
                Dict<String, List<Bool>>,
                Yson::Options(false AS Strict)
            ) AS cb_dict
        FROM $rows_norm
        WHERE cbB_yson IS NOT NULL AND NOT Yson::IsList(cbB_yson)
    ) AS rn
    FLATTEN DICT BY cb_dict AS item
    WHERE CAST(ListLength(item.1) AS Uint64) > rn.idx
);

$cbB_norm = (
    SELECT * FROM $cbB_from_dict_bool
    UNION ALL
    SELECT * FROM $cbB_from_dict_indexed
);

$cbB_key = (
    SELECT
        n.task_id AS task_id,
        n.cb_key AS cb_key,
        MAX(CAST(n.cb_val AS Uint8)) > 0 AS cb_or
    FROM $cbB_norm AS n
    GROUP BY n.task_id, n.cb_key
);

$cbB_instr = (
    SELECT
        k.task_id AS task_id,
        MAX(CASE WHEN k.cb_key = "point_bad_intro" THEN CAST(k.cb_or AS Uint8) ELSE CAST(0 AS Uint8) END) > 0 AS point_bad_intro,
        MAX(CASE WHEN k.cb_key = "point_bad_proactivity" THEN CAST(k.cb_or AS Uint8) ELSE CAST(0 AS Uint8) END) > 0 AS point_bad_proactivity,
        MAX(CASE WHEN k.cb_key = "tov_minus_addressing" THEN CAST(k.cb_or AS Uint8) ELSE CAST(0 AS Uint8) END) > 0 AS tov_minus_addressing,
        MAX(CASE WHEN k.cb_key = "tov_minus_boundary_violation" THEN CAST(k.cb_or AS Uint8) ELSE CAST(0 AS Uint8) END) > 0 AS tov_minus_boundary_violation,
        MAX(CASE WHEN k.cb_key = "tov_minus_cliches" THEN CAST(k.cb_or AS Uint8) ELSE CAST(0 AS Uint8) END) > 0 AS tov_minus_cliches,
        MAX(CASE WHEN k.cb_key = "tov_minus_dry" THEN CAST(k.cb_or AS Uint8) ELSE CAST(0 AS Uint8) END) > 0 AS tov_minus_dry,
        MAX(CASE WHEN k.cb_key = "tov_minus_language_errors" THEN CAST(k.cb_or AS Uint8) ELSE CAST(0 AS Uint8) END) > 0 AS tov_minus_language_errors,
        MAX(CASE WHEN k.cb_key = "tov_minus_overemotional" THEN CAST(k.cb_or AS Uint8) ELSE CAST(0 AS Uint8) END) > 0 AS tov_minus_overemotional,
        MAX(CASE WHEN k.cb_key = "tov_plus_empathy" THEN CAST(k.cb_or AS Uint8) ELSE CAST(0 AS Uint8) END) > 0 AS tov_plus_empathy,
        MAX(CASE WHEN k.cb_key = "tov_plus_humor" THEN CAST(k.cb_or AS Uint8) ELSE CAST(0 AS Uint8) END) > 0 AS tov_plus_humor,
        MAX(CASE WHEN k.cb_key = "tov_plus_subject" THEN CAST(k.cb_or AS Uint8) ELSE CAST(0 AS Uint8) END) > 0 AS tov_plus_subject,
        MAX(CASE WHEN k.cb_key = "tov_plus_tone_match" THEN CAST(k.cb_or AS Uint8) ELSE CAST(0 AS Uint8) END) > 0 AS tov_plus_tone_match,
        MAX(CASE WHEN k.cb_key = "tov_tone_unacceptable" THEN CAST(k.cb_or AS Uint8) ELSE CAST(0 AS Uint8) END) > 0 AS tov_tone_unacceptable
    FROM $cbB_key AS k
    GROUP BY k.task_id
);

$cbB_false_instr = (
    SELECT
        k.task_id AS task_id,
        false AS point_bad_intro,
        false AS point_bad_proactivity,
        false AS tov_minus_addressing,
        false AS tov_minus_boundary_violation,
        false AS tov_minus_cliches,
        false AS tov_minus_dry,
        false AS tov_minus_language_errors,
        false AS tov_minus_overemotional,
        false AS tov_plus_empathy,
        false AS tov_plus_humor,
        false AS tov_plus_subject,
        false AS tov_plus_tone_match,
        false AS tov_tone_unacceptable
    FROM $cbB_key AS k
    GROUP BY k.task_id
);

/* BOOL AGGREGATES */

$flags_instr = (
    SELECT
        rn.task_id AS task_id,
        CASE
            WHEN COUNT(*) = 2 THEN SUM(CASE WHEN rn.diff_pa_vote THEN 1 ELSE 0 END) >= 1
            ELSE 2 * SUM(CASE WHEN rn.diff_pa_vote THEN 1 ELSE 0 END) > COUNT(*)
        END AS diff_pa,
        CASE
            WHEN COUNT(*) = 2 THEN SUM(CASE WHEN rn.dsA_vote THEN 1 ELSE 0 END) >= 1
            ELSE 2 * SUM(CASE WHEN rn.dsA_vote THEN 1 ELSE 0 END) > COUNT(*)
        END AS direct_speech_A,
        CASE
            WHEN COUNT(*) = 2 THEN SUM(CASE WHEN rn.dsB_vote THEN 1 ELSE 0 END) >= 1
            ELSE 2 * SUM(CASE WHEN rn.dsB_vote THEN 1 ELSE 0 END) > COUNT(*)
        END AS direct_speech_B
    FROM $rows_norm AS rn
    GROUP BY rn.task_id
);

/* VOTES + AGREEMENT + STRENGTH */

$votes = (
    SELECT
        rn.task_id AS task_id,
        SOME(rn.source_A) AS source_A,
        SOME(rn.source_B) AS source_B,

        SUM(CASE WHEN rn.skip_vote THEN 1 ELSE 0 END) AS skip_yes,
        COUNT(*) AS skip_n,

        SUM(CASE WHEN rn.sw_raw = rn.source_A THEN 1 ELSE 0 END) AS sw_A,
        SUM(CASE WHEN rn.sw_raw = rn.source_B THEN 1 ELSE 0 END) AS sw_B,
        SUM(CASE WHEN rn.sw_raw = "draw" THEN 1 ELSE 0 END) AS sw_dr,
        SUM(CASE WHEN rn.sw_raw = "both_bad" THEN 1 ELSE 0 END) AS sw_bb,
        SUM(CASE WHEN rn.sw_raw = rn.source_A OR rn.sw_raw = rn.source_B OR rn.sw_raw = "draw" OR rn.sw_raw = "both_bad" THEN 1 ELSE 0 END) AS sw_n,

        SUM(CASE WHEN rn.dp_eff_raw = rn.source_A THEN 1 ELSE 0 END) AS dp_A,
        SUM(CASE WHEN rn.dp_eff_raw = rn.source_B THEN 1 ELSE 0 END) AS dp_B,
        SUM(CASE WHEN rn.dp_eff_raw = "draw" THEN 1 ELSE 0 END) AS dp_dr,
        SUM(CASE WHEN rn.dp_eff_raw = "both_bad" THEN 1 ELSE 0 END) AS dp_bb,
        SUM(CASE WHEN rn.dp_eff_raw = rn.source_A OR rn.dp_eff_raw = rn.source_B OR rn.dp_eff_raw = "draw" OR rn.dp_eff_raw = "both_bad" THEN 1 ELSE 0 END) AS dp_n
    FROM $rows_norm AS rn
    GROUP BY rn.task_id
);

$agg = (
    SELECT
        v.task_id AS task_id,

        CASE
            WHEN v.skip_n = 2 THEN v.skip_yes >= 1
            ELSE 2 * v.skip_yes > v.skip_n
        END AS skip,

        CASE
            WHEN v.sw_n = 0 THEN NULL
            WHEN v.sw_n = 1 THEN 1.0
            ELSE (
                ((v.sw_A * (v.sw_A - 1)) / 2 + (v.sw_B * (v.sw_B - 1)) / 2 + (v.sw_dr * (v.sw_dr - 1)) / 2 + (v.sw_bb * (v.sw_bb - 1)) / 2)
                + (v.sw_dr * v.sw_bb)
                + 0.5 * (v.sw_A * v.sw_dr + v.sw_B * v.sw_dr + v.sw_A * v.sw_bb + v.sw_B * v.sw_bb)
            ) / CAST((v.sw_n * (v.sw_n - 1)) / 2 AS Double)
        END AS source_winner_agreement,

        CASE
            WHEN v.dp_n = 0 THEN NULL
            WHEN v.dp_n = 1 THEN 1.0
            ELSE (
                ((v.dp_A * (v.dp_A - 1)) / 2 + (v.dp_B * (v.dp_B - 1)) / 2 + (v.dp_dr * (v.dp_dr - 1)) / 2 + (v.dp_bb * (v.dp_bb - 1)) / 2)
                + (v.dp_dr * v.dp_bb)
                + 0.5 * (v.dp_A * v.dp_dr + v.dp_B * v.dp_dr + v.dp_A * v.dp_bb + v.dp_B * v.dp_bb)
            ) / CAST((v.dp_n * (v.dp_n - 1)) / 2 AS Double)
        END AS diff_pa_winner_agreement,

        CASE
            WHEN ((CASE WHEN v.skip_n = 2 THEN v.skip_yes >= 1 ELSE 2 * v.skip_yes > v.skip_n END)) OR v.sw_n = 0 THEN NULL
            WHEN 2 * v.sw_A > v.sw_n THEN v.source_A
            WHEN 2 * v.sw_B > v.sw_n THEN v.source_B
            WHEN 2 * v.sw_dr > v.sw_n THEN "draw"
            WHEN 2 * v.sw_bb > v.sw_n THEN "both_bad"
            ELSE CASE
                WHEN v.sw_bb > 0 THEN "both_bad"
                WHEN v.sw_n = 2 AND v.sw_A = 1 AND (v.sw_dr = 1 OR v.sw_bb = 1) THEN v.source_A
                WHEN v.sw_n = 2 AND v.sw_B = 1 AND (v.sw_dr = 1 OR v.sw_bb = 1) THEN v.source_B
                WHEN v.sw_dr > 0 THEN "draw"
                WHEN v.sw_n = 2 AND v.sw_A = 1 AND v.sw_B = 1 THEN "draw"
                ELSE "both_bad"
            END
        END AS source_winner_internal,

        CASE
            WHEN ((CASE WHEN v.skip_n = 2 THEN v.skip_yes >= 1 ELSE 2 * v.skip_yes > v.skip_n END)) OR v.dp_n = 0 THEN NULL
            WHEN 2 * v.dp_A > v.dp_n THEN v.source_A
            WHEN 2 * v.dp_B > v.dp_n THEN v.source_B
            WHEN 2 * v.dp_dr > v.dp_n THEN "draw"
            WHEN 2 * v.dp_bb > v.dp_n THEN "both_bad"
            ELSE CASE
                WHEN v.dp_bb > 0 THEN "both_bad"
                WHEN v.dp_n = 2 AND v.dp_A = 1 AND (v.dp_dr = 1 OR v.dp_bb = 1) THEN v.source_A
                WHEN v.dp_n = 2 AND v.dp_B = 1 AND (v.dp_dr = 1 OR v.dp_bb = 1) THEN v.source_B
                WHEN v.dp_dr > 0 THEN "draw"
                WHEN v.dp_n = 2 AND v.dp_A = 1 AND v.dp_B = 1 THEN "draw"
                ELSE "both_bad"
            END
        END AS diff_pa_winner_internal,

        CASE
            WHEN ((CASE WHEN v.skip_n = 2 THEN v.skip_yes >= 1 ELSE 2 * v.skip_yes > v.skip_n END)) OR v.sw_n = 0 THEN NULL
            WHEN v.sw_n = 1 THEN "strong"
            WHEN (
                (
                    ((v.sw_A * (v.sw_A - 1)) / 2 + (v.sw_B * (v.sw_B - 1)) / 2 + (v.sw_dr * (v.sw_dr - 1)) / 2 + (v.sw_bb * (v.sw_bb - 1)) / 2)
                    + (v.sw_dr * v.sw_bb)
                    + 0.5 * (v.sw_A * v.sw_dr + v.sw_B * v.sw_dr + v.sw_A * v.sw_bb + v.sw_B * v.sw_bb)
                ) / CAST((v.sw_n * (v.sw_n - 1)) / 2 AS Double)
            ) >= 2.0 / 3.0 THEN "strong"
            ELSE "weak"
        END AS source_winner_strength,

        CASE
            WHEN ((CASE WHEN v.skip_n = 2 THEN v.skip_yes >= 1 ELSE 2 * v.skip_yes > v.skip_n END)) OR v.dp_n = 0 THEN NULL
            WHEN v.dp_n = 1 THEN "strong"
            WHEN (
                (
                    ((v.dp_A * (v.dp_A - 1)) / 2 + (v.dp_B * (v.dp_B - 1)) / 2 + (v.dp_dr * (v.dp_dr - 1)) / 2 + (v.dp_bb * (v.dp_bb - 1)) / 2)
                    + (v.dp_dr * v.dp_bb)
                    + 0.5 * (v.dp_A * v.dp_dr + v.dp_B * v.dp_dr + v.dp_A * v.dp_bb + v.dp_B * v.dp_bb)
                ) / CAST((v.dp_n * (v.dp_n - 1)) / 2 AS Double)
            ) >= 2.0 / 3.0 THEN "strong"
            ELSE "weak"
        END AS diff_pa_winner_strength
    FROM $votes AS v
);

$metadata_rows = (
    SELECT
        p.task_id AS task_id,
        SOME(p.instruct_id) AS instruct_id,
        SOME(p.answer_A) AS answer_A,
        SOME(p.answer_B) AS answer_B,
        SOME(p.source_A) AS source_A,
        SOME(p.source_B) AS source_B,
        SOME(p.markers) AS markers,
        SOME(p.annotations) AS annotations,
        SOME(p.checkboxes) AS checkboxes,
        SOME(p.pointwise_A) AS pointwise_A,
        SOME(p.pointwise_B) AS pointwise_B,
        SOME(p.general_comments) AS general_comments,
        SOME(p.comments_A) AS comments_A,
        SOME(p.comments_B) AS comments_B
    FROM $prep AS p
    GROUP BY p.task_id
);

INSERT INTO $output1
SELECT
    s.answer_A AS answer_1,
    s.answer_B AS answer_2,
    s.source_A AS answer_source_1,
    s.source_B AS answer_source_2,
    s.checkboxes AS checkboxes,
    s.checkboxes_1 AS checkboxes_1,
    s.checkboxes_2 AS checkboxes_2,
    s.pointwise_1 AS pointwise_1,
    s.pointwise_2 AS pointwise_2,
    s.comments_A AS comments_1,
    s.comments_B AS comments_2,
    s.direct_speech_A AS direct_speech_1,
    s.direct_speech_B AS direct_speech_2,
    s.general_comments AS general_comment,
    s.instruct_id AS instruct_id,
    s.task_id AS task_id,
    s.annotations AS annotations,
    s.markers AS markers,
    CASE
        WHEN s.markers IS NULL THEN NULL
        ELSE ListFilter(
            s.markers,
            ($m) -> {
                RETURN $m.`group` == "Недостатки";
            }
        )
    END AS markers_bad,
    CASE
        WHEN s.markers IS NULL THEN NULL
        ELSE ListFilter(
            s.markers,
            ($m) -> {
                RETURN $m.`group` != "Недостатки";
            }
        )
    END AS markers_good,
    s.skip AS skip,
    s.source_winner AS source_winner
FROM (
    SELECT
        m.instruct_id AS instruct_id,
        m.task_id AS task_id,
        m.answer_A AS answer_A,
        m.answer_B AS answer_B,
        m.source_A AS source_A,
        m.source_B AS source_B,

        CASE
            WHEN m.checkboxes IS NULL THEN NULL
            ELSE ListMap(
                Yson::ConvertToList(m.checkboxes),
                ($checkbox) -> {
                    RETURN AsStruct(
                        COALESCE(Yson::LookupString($checkbox, "group"), "") AS `group`,
                        COALESCE(Yson::LookupString($checkbox, "id"), "") AS id,
                        COALESCE(Yson::LookupString($checkbox, "label"), "") AS label
                    );
                }
            )
        END AS checkboxes,

        CASE
            WHEN COALESCE(a.skip, false) THEN
                CASE
                    WHEN cA0.task_id IS NULL THEN NULL
                    ELSE AsStruct(
                        COALESCE(cA0.point_bad_intro, false) AS point_bad_intro,
                        COALESCE(cA0.point_bad_proactivity, false) AS point_bad_proactivity,
                        COALESCE(cA0.tov_minus_addressing, false) AS tov_minus_addressing,
                        COALESCE(cA0.tov_minus_boundary_violation, false) AS tov_minus_boundary_violation,
                        COALESCE(cA0.tov_minus_cliches, false) AS tov_minus_cliches,
                        COALESCE(cA0.tov_minus_dry, false) AS tov_minus_dry,
                        COALESCE(cA0.tov_minus_language_errors, false) AS tov_minus_language_errors,
                        COALESCE(cA0.tov_minus_overemotional, false) AS tov_minus_overemotional,
                        COALESCE(cA0.tov_plus_empathy, false) AS tov_plus_empathy,
                        COALESCE(cA0.tov_plus_humor, false) AS tov_plus_humor,
                        COALESCE(cA0.tov_plus_subject, false) AS tov_plus_subject,
                        COALESCE(cA0.tov_plus_tone_match, false) AS tov_plus_tone_match,
                        COALESCE(cA0.tov_tone_unacceptable, false) AS tov_tone_unacceptable
                    )
                END
            ELSE
                CASE
                    WHEN cA.task_id IS NULL THEN NULL
                    ELSE AsStruct(
                        COALESCE(cA.point_bad_intro, false) AS point_bad_intro,
                        COALESCE(cA.point_bad_proactivity, false) AS point_bad_proactivity,
                        COALESCE(cA.tov_minus_addressing, false) AS tov_minus_addressing,
                        COALESCE(cA.tov_minus_boundary_violation, false) AS tov_minus_boundary_violation,
                        COALESCE(cA.tov_minus_cliches, false) AS tov_minus_cliches,
                        COALESCE(cA.tov_minus_dry, false) AS tov_minus_dry,
                        COALESCE(cA.tov_minus_language_errors, false) AS tov_minus_language_errors,
                        COALESCE(cA.tov_minus_overemotional, false) AS tov_minus_overemotional,
                        COALESCE(cA.tov_plus_empathy, false) AS tov_plus_empathy,
                        COALESCE(cA.tov_plus_humor, false) AS tov_plus_humor,
                        COALESCE(cA.tov_plus_subject, false) AS tov_plus_subject,
                        COALESCE(cA.tov_plus_tone_match, false) AS tov_plus_tone_match,
                        COALESCE(cA.tov_tone_unacceptable, false) AS tov_tone_unacceptable
                    )
                END
        END AS checkboxes_1,

        CASE
            WHEN COALESCE(a.skip, false) THEN
                CASE
                    WHEN cB0.task_id IS NULL THEN NULL
                    ELSE AsStruct(
                        COALESCE(cB0.point_bad_intro, false) AS point_bad_intro,
                        COALESCE(cB0.point_bad_proactivity, false) AS point_bad_proactivity,
                        COALESCE(cB0.tov_minus_addressing, false) AS tov_minus_addressing,
                        COALESCE(cB0.tov_minus_boundary_violation, false) AS tov_minus_boundary_violation,
                        COALESCE(cB0.tov_minus_cliches, false) AS tov_minus_cliches,
                        COALESCE(cB0.tov_minus_dry, false) AS tov_minus_dry,
                        COALESCE(cB0.tov_minus_language_errors, false) AS tov_minus_language_errors,
                        COALESCE(cB0.tov_minus_overemotional, false) AS tov_minus_overemotional,
                        COALESCE(cB0.tov_plus_empathy, false) AS tov_plus_empathy,
                        COALESCE(cB0.tov_plus_humor, false) AS tov_plus_humor,
                        COALESCE(cB0.tov_plus_subject, false) AS tov_plus_subject,
                        COALESCE(cB0.tov_plus_tone_match, false) AS tov_plus_tone_match,
                        COALESCE(cB0.tov_tone_unacceptable, false) AS tov_tone_unacceptable
                    )
                END
            ELSE
                CASE
                    WHEN cB.task_id IS NULL THEN NULL
                    ELSE AsStruct(
                        COALESCE(cB.point_bad_intro, false) AS point_bad_intro,
                        COALESCE(cB.point_bad_proactivity, false) AS point_bad_proactivity,
                        COALESCE(cB.tov_minus_addressing, false) AS tov_minus_addressing,
                        COALESCE(cB.tov_minus_boundary_violation, false) AS tov_minus_boundary_violation,
                        COALESCE(cB.tov_minus_cliches, false) AS tov_minus_cliches,
                        COALESCE(cB.tov_minus_dry, false) AS tov_minus_dry,
                        COALESCE(cB.tov_minus_language_errors, false) AS tov_minus_language_errors,
                        COALESCE(cB.tov_minus_overemotional, false) AS tov_minus_overemotional,
                        COALESCE(cB.tov_plus_empathy, false) AS tov_plus_empathy,
                        COALESCE(cB.tov_plus_humor, false) AS tov_plus_humor,
                        COALESCE(cB.tov_plus_subject, false) AS tov_plus_subject,
                        COALESCE(cB.tov_plus_tone_match, false) AS tov_plus_tone_match,
                        COALESCE(cB.tov_tone_unacceptable, false) AS tov_tone_unacceptable
                    )
                END
        END AS checkboxes_2,

        -- Оценки идут как есть из первого этапа: словарь критерий -> список
        -- оценок по разметчикам.
        m.pointwise_A AS pointwise_1,
        m.pointwise_B AS pointwise_2,

        m.comments_A AS comments_A,
        m.comments_B AS comments_B,

        CASE
            WHEN COALESCE(a.skip, false) THEN false
            ELSE f.direct_speech_A
        END AS direct_speech_A,

        CASE
            WHEN COALESCE(a.skip, false) THEN false
            ELSE f.direct_speech_B
        END AS direct_speech_B,

        m.general_comments AS general_comments,

        CAST(
            CASE
                WHEN COALESCE(a.skip, false) THEN Yson::Serialize(Yson::From(AsList()))
                ELSE COALESCE(m.annotations, Yson::Serialize(Yson::From(AsList())))
            END
            AS Yson?
        ) AS annotations,

        CASE
            WHEN m.markers IS NULL THEN NULL
            ELSE ListMap(
                Yson::ConvertToList(m.markers),
                ($marker) -> {
                    RETURN AsStruct(
                        COALESCE(Yson::LookupString($marker, "color"), "") AS color,
                        COALESCE(Yson::LookupString($marker, "group"), "") AS `group`,
                        COALESCE(Yson::LookupString($marker, "label"), "") AS label,
                        COALESCE(Yson::LookupString($marker, "value"), "") AS value
                    );
                }
            )
        END AS markers,

        COALESCE(a.skip, false) AS skip,
        a.source_winner_internal AS source_winner
    FROM $metadata_rows AS m
    LEFT JOIN $agg AS a
        ON m.task_id = a.task_id
    LEFT JOIN $flags_instr AS f
        ON m.task_id = f.task_id
    LEFT JOIN $cbA_instr AS cA
        ON m.task_id = cA.task_id
    LEFT JOIN $cbB_instr AS cB
        ON m.task_id = cB.task_id
    LEFT JOIN $cbA_false_instr AS cA0
        ON m.task_id = cA0.task_id
    LEFT JOIN $cbB_false_instr AS cB0
        ON m.task_id = cB0.task_id
) AS s
;
