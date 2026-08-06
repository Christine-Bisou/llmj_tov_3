PRAGMA Yson.AutoConvert;
PRAGMA yson.DisableStrict;
PRAGMA SimpleColumns;
PRAGMA AnsiOptionalAs;
PRAGMA yt.UseNativeYtTypes;
PRAGMA AnsiInForEmptyOrNullableItemsCollections;
PRAGMA yt.InferSchema = '1';

DECLARE $input1 AS String;   -- выход markers_stars_pointwise_parse.sql (черновик, 478 строк)
DECLARE $input2 AS String;   -- исходная таблица с for_join (535 строк) — она задаёт состав выхода
DECLARE $output1 AS String;

-- Сборка входа для второго этапа (v4: аудит черновика + SbS вердикт).
-- Черновик (markers_1_answer / markers_2_answer, model_1_analysis /
-- model_2_analysis, model_N_linguistic_scan, pointwise_1 / pointwise_2)
-- приезжает из $input1.
-- Парсить dst здесь больше не нужно.
--
-- Состав строк задаёт $input2, а не $input1: поинтвайзный проход теряет
-- строки (не распарсился ответ, схлопнулись полные дубли), и если вести
-- отбор от него, потери едут дальше по конвейеру молча. LEFT JOIN от
-- $input2 гарантирует ровно те же строки и тот же for_join, что в исходнике.
--
-- ЭТО ОБРАТНЫЙ ПОРЯДОК: первым идёт answer_2. Прямой — в файле
-- stars_sbs_v4_input.sql, питон-блок там обязан совпадать с этим до буквы:
-- расходятся — расходятся и два прогона.
--
-- В ответе на этот прогон model_1 означает answer_2 — нормализовать при
-- склейке, как это делает judge_merge_pretty.sql через $flip.
--
-- prompt_template.txt — это prompts/tov_stars_sbs_v4_audit.md
-- (девять плейсхолдеров, см. вызов render ниже).
$template = cast(FileContent("prompt_template.txt") as Utf8);

$script = @@#py
import re
import json
import base64
import urllib.request
from yql.typing import *
from jinja2 import Template


_ALICE_PATTERN = re.compile(
    r'(?i)\b(?:алис[аеуоы]?|алисо[йю]|алисочк[аеиу]|алисоньк[аеиу]|алисик|'
    r'алиск(?:а|и|е|у|ой|ою|ам|ами|ах)?|алисок|alice)\b'
)


def _alice_word(word):
    lw = word.lower()
    if lw == 'алиса': res = 'ева'
    elif lw == 'алисы': res = 'евы'
    elif lw == 'алисе': res = 'еве'
    elif lw == 'алису': res = 'еву'
    elif lw == 'алисой': res = 'евой'
    elif lw == 'алисою': res = 'евою'
    elif lw == 'алис': res = 'ева'
    elif lw.startswith('алисочк'): res = lw.replace('алисочк', 'евочк')
    elif lw.startswith('алисоньк'): res = lw.replace('алисоньк', 'евоньк')
    elif lw.startswith('алисик'): res = lw.replace('алисик', 'евик')
    elif lw == 'алисок': res = 'евок'
    elif lw.startswith('алиск'): res = lw.replace('алиск', 'евк')
    elif lw == 'alice': res = 'eva'
    else: res = 'ева'

    if word.isupper(): return res.upper()
    if word.istitle(): return res.capitalize()
    return res


def _replace_alice(text):
    if not text:
        return ''
    return _ALICE_PATTERN.sub(lambda m: _alice_word(m.group(0)), str(text))


def _image_to_base64(url):
    with urllib.request.urlopen(url, timeout=20) as resp:
        return base64.b64encode(resp.read()).decode('utf-8')


def _extract_text_and_images(content):
    if content is None:
        return '', []
    if isinstance(content, str):
        return content, []
    if not isinstance(content, list):
        return str(content), []

    parts, images = [], []
    for item in content:
        if not isinstance(item, dict):
            continue
        item_type = item.get('type')
        if item_type == 'text':
            parts.append(str(item.get('text') or ''))
        elif item_type == 'image_url':
            img = item.get('image_url')
            url = ''
            if isinstance(img, dict):
                url = str(img.get('url') or '')
            elif isinstance(img, str):
                url = img
            if url:
                images.append(url)
                parts.append('[картинка]')
    return ' '.join(p for p in parts if p).strip(), images


def _format_json(raw):
    """Разметка и звёзды приезжают JSON-строкой из Yson::SerializeJson.
    Разворачиваем в читаемый вид: джадж должен видеть структуру, а не
    однострочную кашу. Кривой JSON отдаём как есть, пустой — как {}."""
    if not raw:
        return '{}'
    if isinstance(raw, bytes):
        raw = raw.decode('utf-8', errors='ignore')
    raw = str(raw)
    try:
        return json.dumps(json.loads(raw), ensure_ascii=False, indent=2)
    except Exception:
        return raw


def replace_alice(text: Optional[Utf8]) -> Optional[Utf8]:
    return _replace_alice(text)


def build_judge_input(
    dialog_json: Optional[Utf8],
    template: Optional[Utf8],
    answer_1: Optional[Utf8],
    answer_2: Optional[Utf8],
    analysis_1: Optional[Utf8],
    analysis_2: Optional[Utf8],
    markers_1_json: Optional[Utf8],
    markers_2_json: Optional[Utf8],
    pointwise_1_json: Optional[Utf8],
    pointwise_2_json: Optional[Utf8]
) -> Optional[Utf8]:
    """Собирает вход второго этапа: пара ответов + черновая разметка
    поинтвайзного прохода по каждому из них (маркеры, разбор, звёзды)."""
    MAX_MESSAGES = 5

    try:
        dialog = json.loads(dialog_json) if dialog_json else []
    except Exception:
        dialog = []
    if not isinstance(dialog, list):
        dialog = []

    if len(dialog) > MAX_MESSAGES:
        dialog = dialog[-MAX_MESSAGES:]

    dialog_lines = []
    image_urls = []
    for msg in dialog:
        if not isinstance(msg, dict):
            continue
        role = msg.get('role', 'user')
        text, msg_images = _extract_text_and_images(msg.get('content'))
        text = _replace_alice(text)
        prefix = 'Пользователь: ' if role == 'user' else 'Ассистент: '
        dialog_lines.append(prefix + text)
        image_urls.extend(msg_images)

    context_with_query = '\n\n'.join(dialog_lines)

    rendered = Template(str(template or '')).render(
        context_with_query=context_with_query,
        model_1_answer=_replace_alice(answer_1),
        model_2_answer=_replace_alice(answer_2),
        model_1_analysis=_replace_alice(analysis_1),
        model_2_analysis=_replace_alice(analysis_2),
        # в explanation маркеров лежат цитаты из ответа — их тоже переименовываем,
        # иначе джадж увидит «Алису» в цитате и «Еву» в самом ответе
        markers_1_answer=_replace_alice(_format_json(markers_1_json)),
        markers_2_answer=_replace_alice(_format_json(markers_2_json)),
        pointwise_1=_replace_alice(_format_json(pointwise_1_json)),
        pointwise_2=_replace_alice(_format_json(pointwise_2_json)),
    )

    if not image_urls:
        out = [{'role': 'user', 'content': rendered}]
        return json.dumps(out, ensure_ascii=False)

    content = []
    for url in image_urls:
        if url.startswith('data:'):
            data_url = url
        else:
            try:
                b64 = _image_to_base64(url)
            except Exception:
                continue
            data_url = 'data:image/jpeg;base64,' + b64
        content.append({
            'type': 'image_url',
            'image_url': {'url': data_url, 'detail': 'auto'},
        })
    content.append({'type': 'text', 'text': rendered})
    out = [{'role': 'user', 'content': content}]
    return json.dumps(out, ensure_ascii=False)
@@;

$build_judge_input = Python3::build_judge_input($script);

-- Ключ склейки с черновиком. По for_join склеиться нельзя: в выходе
-- поинтвайза этой колонки нет, а его instruct_id — сквозная нумерация
-- 1..478 самой таблицы. Поэтому по содержанию пары: вопрос + оба ответа
-- + оба источника (см. sql/missing_for_join.sql, тот же ключ).
-- Когда поинтвайз начнёт протаскивать for_join, весь этот блок заменяется
-- на USING (for_join).
$key = ($instruct, $a1, $a2, $s1, $s2) -> {
    RETURN Digest::Md5Hex(
        COALESCE(CAST($instruct AS String), '') || '\x01' ||
        COALESCE(CAST($a1 AS String), '')       || '\x01' ||
        COALESCE(CAST($a2 AS String), '')       || '\x01' ||
        COALESCE(CAST($s1 AS String), '')       || '\x01' ||
        COALESCE(CAST($s2 AS String), '')
    );
};

-- Черновик: только то, что нужно шаблону. Ключ здесь уникален (478 строк —
-- 478 ключей), так что LEFT JOIN ниже строки не размножит.
$draft = (
    SELECT
        $key(instruct, answer_1, answer_2, answer_source_1, answer_source_2) AS k,
        model_1_analysis        AS model_1_analysis,
        model_2_analysis        AS model_2_analysis,
        -- в шаблон второго этапа скан не идёт, но дальше по конвейеру нужен:
        -- склейка кладёт его в разметку вторым комментарием
        model_1_linguistic_scan AS model_1_linguistic_scan,
        model_2_linguistic_scan AS model_2_linguistic_scan,
        markers_1_answer        AS markers_1_answer,
        markers_2_answer        AS markers_2_answer,
        pointwise_1             AS pointwise_1,
        pointwise_2             AS pointwise_2
    FROM $input1
);

-- Состав и порядок строк — как в исходнике, все 535
$src = (
    SELECT
        $key(instruct, answer_1, answer_2, answer_source_1, answer_source_2) AS k,
        t.*
    FROM $input2 AS t
);

-- Ответы переставлены местами, и вместе с ними — весь черновик: на позицию 1
-- едет answer_2 со своими markers_2_answer / model_2_analysis / pointwise_2,
-- на позицию 2 — answer_1 со своими. Перепутать половины нельзя: джадж будет
-- сверять цитаты по чужому тексту, не найдёт их и снесёт всю разметку как
-- «маркер без цитаты» — это будет выглядеть не сбоем, а работой аудита.
INSERT INTO $output1 WITH TRUNCATE
SELECT
  Yson::ParseJson(
    $build_judge_input(
      Yson::SerializeJson(Yson::From(s.dialog)),
      $template,
      cast(s.answer_2 as Utf8),
      cast(s.answer_1 as Utf8),
      cast(d.model_2_analysis as Utf8),
      cast(d.model_1_analysis as Utf8),
      cast(Yson::SerializeJson(d.markers_2_answer) as Utf8),
      cast(Yson::SerializeJson(d.markers_1_answer) as Utf8),
      cast(Yson::SerializeJson(d.pointwise_2) as Utf8),
      cast(Yson::SerializeJson(d.pointwise_1) as Utf8)
    )
  ) AS infer_dialog,

  -- у строк, до которых поинтвайз не доехал, черновика нет: шаблон получит
  -- пустые {} и аудировать будет нечего. Флаг нужен, чтобы такие строки было
  -- видно на выходе, а не искать их потом сверкой с исходником
  (d.k IS NOT NULL)         AS has_draft,

  d.model_1_analysis        AS model_1_analysis,
  d.model_2_analysis        AS model_2_analysis,
  d.model_1_linguistic_scan AS model_1_linguistic_scan,
  d.model_2_linguistic_scan AS model_2_linguistic_scan,
  d.markers_1_answer        AS markers_1_answer,
  d.markers_2_answer        AS markers_2_answer,
  d.pointwise_1             AS pointwise_1,
  d.pointwise_2             AS pointwise_2,

  -- WITHOUT обязан быть последним элементом списка
  s.* WITHOUT IF EXISTS s.k, s.tov_prompt, s._other, s.infer_dialog, s.dst, s.reasoning_dst
FROM $src AS s
LEFT JOIN $draft AS d
ON s.k = d.k;
