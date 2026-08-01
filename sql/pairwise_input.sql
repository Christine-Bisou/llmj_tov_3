PRAGMA Yson.AutoConvert;
PRAGMA yson.DisableStrict;
PRAGMA SimpleColumns;
PRAGMA AnsiOptionalAs;
PRAGMA yt.UseNativeYtTypes;
PRAGMA AnsiInForEmptyOrNullableItemsCollections;
PRAGMA yt.InferSchema = '1';

DECLARE $tables_list AS List<String>;
DECLARE $out_table AS String;

$template = cast(FileContent("prompt_pairwise.txt") as Utf8);

-- порог разрыва: пары с |overall_1 - overall_2| <= $gap уходят на пересуд
$gap = 1.0;

-- Всё берём из meta_info: колонок m1_overall_avg / tov_winner может не быть,
-- а meta_info пишется скриптом склейки всегда.
$num = ($mi, $key) -> {
    RETURN Yson::ConvertToDouble(Yson::Lookup($mi, $key)) ?? 0.0;
};

$overall_1 = ($mi) -> {
    RETURN ($num($mi, 'direct_m1_overall') + $num($mi, 'reversed_m1_overall')) / 2.0;
};

$overall_2 = ($mi) -> {
    RETURN ($num($mi, 'direct_m2_overall') + $num($mi, 'reversed_m2_overall')) / 2.0;
};

-- та же логика, что и в скрипте склейки
$verdict = ($mi) -> {
    $d = Yson::LookupString($mi, 'model_winner_direct') ?? 'draw';
    $r = Yson::LookupString($mi, 'model_winner_reversed_normalized') ?? 'draw';
    RETURN CASE
        WHEN $d = $r                      THEN $d
        WHEN $d IN ('draw', 'tie')        THEN $r
        WHEN $r IN ('draw', 'tie')        THEN $d
        ELSE 'draw'
    END;
};

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


def build_pairwise_input(
    dialog_json: Optional[Utf8],
    template: Optional[Utf8],
    answer_a: Optional[Utf8],
    answer_b: Optional[Utf8]
) -> Optional[Utf8]:
    """Собирает вход для сравнительного джаджа.
    Маркеры и анализ первого этапа сюда НЕ передаются намеренно:
    нужно независимое мнение, иначе третий проход воспроизведёт вывод второго."""
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
        model_1_answer=_replace_alice(answer_a),
        model_2_answer=_replace_alice(answer_b),
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

$build_pairwise_input = Python3::build_pairwise_input($script);

INSERT INTO $out_table WITH TRUNCATE
SELECT
  -- прямой порядок: answer_1 идёт первым
  Yson::ParseJson(
    $build_pairwise_input(
      Yson::SerializeJson(Yson::From(res.dialog)),
      $template,
      cast(res.answer_1 as Utf8),
      cast(res.answer_2 as Utf8)
    )
  ) AS infer_dialog,

  -- обратный порядок: answer_2 идёт первым.
  -- В ответе на него model_1 означает answer_2 — нормализовать при склейке.
  Yson::ParseJson(
    $build_pairwise_input(
      Yson::SerializeJson(Yson::From(res.dialog)),
      $template,
      cast(res.answer_2 as Utf8),
      cast(res.answer_1 as Utf8)
    )
  ) AS infer_dialog_rev,

  $overall_1(res.meta_info) AS pair_overall_1,
  $overall_2(res.meta_info) AS pair_overall_2,
  $verdict(res.meta_info)   AS pair_verdict_stage2,

  res.* WITHOUT if exists res._other, res.infer_dialog, res.infer_dialog_rev
FROM (
  SELECT t.*
  FROM Each($tables_list) as t
  WHERE
    -- близкая пара: звёзды второго этапа почти не различают ответы
    ABS($overall_1(t.meta_info) - $overall_2(t.meta_info)) <= $gap
    -- ничьи не трогаем: внутри близких пар они дают 0.70, выше среднего
    AND $verdict(t.meta_info) NOT IN ('draw', 'tie')
) res;
