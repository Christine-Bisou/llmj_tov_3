DECLARE $input1 AS String;
DECLARE $output1 AS String;

INSERT INTO $output1
SELECT
    CASE
        WHEN date >= "2026-07-14" AND date <= "2026-08-02" AND worker_group = "editors" THEN 0.789
        ELSE analysts_management_quality_strict
    END AS analysts_management_quality_strict,

    CASE
        WHEN date >= "2026-07-14" AND date <= "2026-08-02" AND worker_group = "editors" THEN 0.842
        ELSE analysts_management_quality_with_half
    END AS analysts_management_quality_with_half,

    asessors_consistency,
    asessors_editors_quality_strict,
    asessors_editors_quality_with_half,
    assessor_error_summary,
    avg_comment_score,
    avg_minutes,

    CASE
        WHEN date >= "2026-07-14" AND date <= "2026-08-02" AND worker_group = "editors" THEN 0.55
        ELSE chiefs_analysts_quality_strict
    END AS chiefs_analysts_quality_strict,

    CASE
        WHEN date >= "2026-07-14" AND date <= "2026-08-02" AND worker_group = "editors" THEN 0.6
        ELSE chiefs_analysts_quality_with_half
    END AS chiefs_analysts_quality_with_half,

    CASE
        WHEN date >= "2026-07-14" AND date <= "2026-08-02" AND worker_group = "editors" THEN 0.55
        ELSE chiefs_management_quality_strict
    END AS chiefs_management_quality_strict,

    CASE
        WHEN date >= "2026-07-14" AND date <= "2026-08-02" AND worker_group = "editors" THEN 0.6
        ELSE chiefs_management_quality_with_half
    END AS chiefs_management_quality_with_half,

    date,

    CASE
        WHEN date >= "2026-07-14" AND date <= "2026-08-02" AND worker_group = "editors" THEN NULL
        ELSE editors_analysts_quality_strict
    END AS editors_analysts_quality_strict,

    CASE
        WHEN date >= "2026-07-14" AND date <= "2026-08-02" AND worker_group = "editors" THEN NULL
        ELSE editors_analysts_quality_with_half
    END AS editors_analysts_quality_with_half,

    editors_chiefs_quality_strict,
    editors_chiefs_quality_with_half,
    editors_consistency,

    CASE
        WHEN date >= "2026-07-14" AND date <= "2026-08-02" AND worker_group = "editors" THEN 0.4
        ELSE editors_management_quality_strict
    END AS editors_management_quality_strict,

    CASE
        WHEN date >= "2026-07-14" AND date <= "2026-08-02" AND worker_group = "editors" THEN 0.55
        ELSE editors_management_quality_with_half
    END AS editors_management_quality_with_half,

    tasks,
    worker_group,
    workers
FROM $input1;
