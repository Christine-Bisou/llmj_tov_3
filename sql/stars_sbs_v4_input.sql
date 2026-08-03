PRAGMA Yson.AutoConvert;
PRAGMA yson.DisableStrict;
PRAGMA SimpleColumns;
PRAGMA AnsiOptionalAs;
PRAGMA yt.UseNativeYtTypes;
PRAGMA AnsiInForEmptyOrNullableItemsCollections;
PRAGMA yt.InferSchema = '1';

DECLARE $input1 AS String;
DECLARE $output1 AS String;

-- Сборка входа для второго этапа (v4: аудит черновика + SbS вердикт).
-- $input1 — выход markers_stars_pointwise_parse.sql: там уже лежат
-- markers_1_answer / markers_2_answer, model_1_analysis / model_2_analysis
-- и pointwise_1 / pointwise_2. Парсить dst здесь больше не нужно.
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

INSERT INTO $output1 WITH TRUNCATE
SELECT
  Yson::ParseJson(
    $build_judge_input(
      Yson::SerializeJson(Yson::From(t.dialog)),
      $template,
      -- порядок строго 1 к 1, 2 к 2: черновик должен приехать к своему ответу
      cast(t.answer_1 as Utf8),
      cast(t.answer_2 as Utf8),
      cast(t.model_1_analysis as Utf8),
      cast(t.model_2_analysis as Utf8),
      cast(Yson::SerializeJson(t.markers_1_answer) as Utf8),
      cast(Yson::SerializeJson(t.markers_2_answer) as Utf8),
      cast(Yson::SerializeJson(t.pointwise_1) as Utf8),
      cast(Yson::SerializeJson(t.pointwise_2) as Utf8)
    )
  ) AS infer_dialog,

  -- WITHOUT обязан быть последним элементом списка
  t.* WITHOUT IF EXISTS t.tov_prompt, t._other, t.infer_dialog, t.dst, t.reasoning_dst
FROM $input1 AS t;
