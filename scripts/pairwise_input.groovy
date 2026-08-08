// Формирование входных данных для разметки (pairwise).
// Набор маркеров и структура input_values синхронизированы со вторым проектом:
// те же value/group/color у маркеров, тот же набор ключей в JSON.

def MARKERS = [
  [label:"❇️ Ясность изложения", value:"tov_plus_clarity", group:"Кайфули", color:"#7ED957"],
  [label:"💚 Эмпатия", value:"tov_plus_empathy", group:"Кайфули", color:"#4CAF50"],
  [label:"🧚 Субъектность", value:"tov_plus_subject", group:"Кайфули", color:"#2F9E6E"],
  [label:"🍀 Попадание в тон и настроение", value:"tov_plus_tone_match", group:"Кайфули", color:"#2E7D32"],
  [label:"🥒 Словесные пряности", value:"tov_plus_humor", group:"Кайфули", color:"#9CCC3C"],

  [label:"💔 Гиперэмо", value:"tov_minus_overemotional", group:"Недостатки", color:"#E53935"],
  [label:"📕 Тяжелое восприятие", value:"tov_minus_dry", group:"Недостатки", color:"#6D4C41"],
  [label:"💋 Нарушение личных границ пользователя", value:"tov_minus_boundary_violation", group:"Недостатки", color:"#EC407A"],
  [label:"🤖 Роботность", value:"tov_minus_cliches", group:"Недостатки", color:"#F0625D"],
  [label:"😡 Ошибки языка", value:"tov_minus_language_errors", group:"Недостатки", color:"#FF1744"],
  [label:"🚨 Неопределенность в обращении к пользователю", value:"tov_minus_addressing", group:"Недостатки", color:"#AD1457"],
]

def CHECKBOXES = [
  [group:"Проставьте вручную", id:"tov_tone_unacceptable",     label:"🧊 Критично недопустимый тон"],
  [group:"Проставьте вручную", id:"point_bad_intro",           label:"👺 Недочёты во вступлении"],
  [group:"Проставьте вручную", id:"point_bad_proactivity",     label:"🥊 Недочёты в проактивности"],
]

// В этом проекте нет колонок ticket / basket_table / meta, но ключи оставляем,
// чтобы схема JSON совпадала со вторым проектом. Если колонки появятся —
// заменить "" на it.ticket / it.basket_table / it.meta.
in0.eachWithIndex { it, idx ->
  def res = [:]
  res.id = idx.toString()

  res.input_values = [
    metadata: [
        ticket: "",
        instruct_id: it.instruct_id,
        basket_table: "",
        priority_type: it.priority_type,
        pool_type: it.pool_type,
        meta: "",
        models: [
            model_1: it.source_A,
            model_2: it.source_B
        ]

    ],
    markers: MARKERS,
    checkboxes: CHECKBOXES,
    dialog: [],
    dialog_altformat: it.converted_dialog,
    answers: [
        [answer: it.answer_A, label: "A", source: it.source_A, id: "0"],
        [answer: it.answer_B, label: "B", source: it.source_B, id: "1"],
    ],
    need_pointwise: true
]


  out.write(res)
}
