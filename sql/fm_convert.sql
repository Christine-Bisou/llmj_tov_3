DECLARE $input1 AS String;
DECLARE $output1 AS String;

PRAGMA yt.InferSchema = '1';
PRAGMA yt.UseNativeYtTypes;
PRAGMA Yson.AutoConvert;
PRAGMA yt.MaxRowWeight = "128M";
PRAGMA yt.DefaultMemoryLimit = '12G';
PRAGMA yt.UseTmpfs = 'true';
PRAGMA yt.ExtraTmpfsSize = '1G';

PRAGMA File(
    "latest_libmulti_udf.so",
    "yt://hahn/home/ranking/prod_build_artifacts_storage/latest_libmulti_udf.so"
);
PRAGMA Udf("latest_libmulti_udf.so");
PRAGMA Layer=@@{
    "name": "base"
}@@;
PRAGMA Layer=@@{
    "name": "python_bootstrap",
    "parent": "base"
}@@;
PRAGMA hahn.LayerCaches=@@{
    "name": "base",
    "paths": ["//porto_layers/base/bionic/porto_layer_search_ubuntu_bionic_app_latest.tar.gz"]
}@@;
PRAGMA hahn.LayerCaches=@@{
    "name": "python_bootstrap",
    "paths": ["//home/ranking/prod_build_artifacts_storage/porto_layers/latest_python_bootstrap.tar.gz"]
}@@;

$runner = Udf(GraphExec::RunnerWithSkips, ["python_bootstrap"] AS Layers);
$graph_state = FileContent("graph_state");

$prepare_graph_script = @@#py3
import json
from yt.yson import dumps, loads


def _decode(value):
    """Строка из YT: обычный utf-8, бинарный yson-узел или битые байты."""
    if not isinstance(value, bytes):
        return value
    if value[:1] == b"\x01":
        # Скалярная Yson-колонка отдаётся в Python не текстом, а сырым
        # yson-узлом: 0x01, зигзаг-длина, и только потом сами байты строки.
        try:
            node = loads(value)
        except Exception:
            node = None
        if isinstance(node, str):
            return node
        if isinstance(node, bytes):
            value = node
    # Битый байт в одном ответе не должен ронять всю операцию: джоб уходит
    # в ретраи на той же строке и выжигает max_failed_job_count.
    return value.decode("utf-8", "replace")


def _load_json(value):
    return json.loads(_decode(value))


def prepare(graph_state, input_final_messages, input_meta, answer, timestamp_seconds):
    state = _load_json(graph_state)
    messages = _load_json(input_final_messages)
    meta = _load_json(input_meta)
    answer = _decode(answer)

    last_extra = messages[-1].get("extra_info", {})
    instruct_id = meta["instruct_id"]
    dialog = {
        "messages": [
            {
                "content": "REPLACE_ME_FAKE_FOR_VLM_FM_CONVERTER_JARVIS",
                "extra_info": {"timestamp_seconds": int(timestamp_seconds)},
                "role": "user",
            }
        ],
        "meta": {
            "device": last_extra.get("device", "DESKTOP"),
            "input_type": "text",
            "instruct_id": instruct_id,
            "region_id": last_extra.get("region_id", "213"),
            "session_id": instruct_id,
            "tags": meta.get("tags", []),
            "user_latitude": last_extra.get("user_latitude"),
            "user_longitude": last_extra.get("user_longitude"),
            "voice_output": "auto",
        },
    }
    planner_report = {
        "is_valid": True,
        "iteration": 4,
        "meta": "BT_FAKE_PLANNER",
        "queries": [
            {"format": None, "iteration": "1", "text": "query", "type": "WEB"},
            {"format": "single", "iteration": 3, "text": "query", "type": "IMAGE"},
            {"format": "single", "iteration": 4, "text": "query", "type": "VIDEO"},
        ],
    }
    replacements = {
        "final_content_sources.json": [],
        "neuro_alice_answer_wout_reasoning": answer,
        "generator_dialog.json": dialog,
        "planner_report.json": planner_report,
    }

    for item in state.get("StaticData", []):
        data_id = item.get("DataRef", {}).get("DataId")
        if data_id in replacements:
            item["Payload"] = json.dumps(replacements[data_id], ensure_ascii=False)

    return dumps(state)
@@;

$prepare_graph = Python3::prepare(
    Callable<(String, String, String, String, Uint64) -> Yson>,
    $prepare_graph_script
);

$build_output_script = @@#py3
import copy
import json
from yt.yson import dumps, loads


def _decode(value):
    """Строка из YT: обычный utf-8, бинарный yson-узел или битые байты."""
    if not isinstance(value, bytes):
        return value
    if value[:1] == b"\x01":
        # Скалярная Yson-колонка отдаётся в Python не текстом, а сырым
        # yson-узлом: 0x01, зигзаг-длина, и только потом сами байты строки.
        try:
            node = loads(value)
        except Exception:
            node = None
        if isinstance(node, str):
            return node
        if isinstance(node, bytes):
            value = node
    # Битый байт в одном ответе не должен ронять всю операцию: джоб уходит
    # в ретраи на той же строке и выжигает max_failed_job_count.
    return value.decode("utf-8", "replace")


def _load_json(value):
    return json.loads(_decode(value))


def build(result, input_final_messages, input_meta, answer_source):
    # Ошибку одной строки гасим здесь, иначе весь запрос падает из-за одного графа.
    try:
        state = _load_json(result)

        payloads = {}
        for item in state.get("ProducedData", []):
            data_ref = item.get("DataRef", {})
            if data_ref.get("IsFinalState", False):
                payloads[data_ref.get("DataId")] = item.get("Payload")

        converted_messages = _load_json(payloads["final_messages.json"])
        render_data = _load_json(payloads["render_data.json"])
        original_messages = _load_json(input_final_messages)
        meta = _load_json(input_meta)

        final_messages = [copy.deepcopy(converted_messages[0])]
        final_messages.extend(copy.deepcopy(original_messages[1:]))
        final_messages[-1]["extra_info"] = copy.deepcopy(converted_messages[1]["extra_info"])
        final_messages.extend(copy.deepcopy(converted_messages[2:]))

        row = {
            "answers": [
                {
                    "final_messages": final_messages,
                    "meta": {
                        "env": meta.get("env"),
                        "tools": "default",
                        "tags": meta.get("tags", []),
                    },
                    "render_data": render_data,
                    "answer_producer": {"name": _decode(answer_source)},
                    "answer_html_url": None,
                }
            ],
            "input_final_messages": original_messages,
            "input_meta": meta,
            "input_render_data": None,
        }
        return dumps({"ok": True, "row": row})
    except Exception as error:
        return dumps({"ok": False, "error": str(error)[:2000]})
@@;

$build_output = Python3::build(
    Callable<(String, String, String, String) -> Yson>,
    $build_output_script
);

$to_json_bytes = ($value) -> {
    RETURN ToBytes(Yson::SerializeJson($value));
};

$rows = (
    SELECT
        COALESCE(Yson::ConvertToString(input_meta["instruct_id"]), "") AS instruct_id,
        input_final_messages,
        input_meta,
        input_render_data,
        answer,
        answer_source,
        answer_index
    FROM $input1
);

$executed = (
    SELECT
        instruct_id,
        answer_index,
        input_final_messages,
        input_meta,
        input_render_data,
        answer_source,
        Yson::From($runner(<|
            GraphForExecution: Unwrap(ToBytes($to_json_bytes($prepare_graph(
                $graph_state,
                Unwrap($to_json_bytes(input_final_messages)),
                Unwrap($to_json_bytes(input_meta)),
                answer,
                Unwrap(CAST(CurrentUtcTimestamp() AS Uint64) / 1000000u)
            )))),
            NodeTypesToSkip: {},
            NodeIdsToSkip: []
        |>)) AS graph_result
    FROM $rows
);

$built = (
    SELECT
        instruct_id,
        answer_index,
        input_final_messages,
        input_meta,
        input_render_data,
        $build_output(
            Unwrap($to_json_bytes(graph_result)),
            Unwrap($to_json_bytes(input_final_messages)),
            Unwrap($to_json_bytes(input_meta)),
            answer_source
        ) AS packed
    FROM $executed
);

$successful = (
    SELECT
        instruct_id,
        answer_index,
        input_final_messages,
        input_meta,
        input_render_data,
        Yson::SerializeJson(
            Unwrap(Yson::ConvertToList(Yson::Lookup(Yson::Lookup(packed, "row"), "answers")))[0]
        ) AS answer_json
    FROM $built
    WHERE Yson::LookupBool(packed, "ok") ?? FALSE
);

-- Канонический FM всех моделей: ровно 4 верхнеуровневые колонки.
-- Ответы внутри instruct_id складываются в список в порядке answer_index,
-- поля корзины у всех строк группы одинаковые, поэтому берём любое через SOME().
INSERT INTO $output1 WITH TRUNCATE
SELECT
    Yson::From(ListMap(
        ListSort(
            AGGREGATE_LIST(AsStruct(
                answer_index AS answer_index,
                answer_json AS answer_json
            )),
            ($item) -> ($item.answer_index)
        ),
        ($item) -> (Yson::ParseJson($item.answer_json))
    )) AS answers,
    SOME(input_final_messages) AS input_final_messages,
    SOME(input_meta) AS input_meta,
    SOME(input_render_data) AS input_render_data
FROM $successful
GROUP BY instruct_id;
