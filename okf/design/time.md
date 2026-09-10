---
type: Design
title: "Многомерное логическое время Ariadne"
description: "Представление эпох и координат вложенных циклов."
status: draft
tags: [ariadne, time, timely-dataflow, design]
sources:
  - id: timely-dataflow-model
    resource: ../references/papers/timely-dataflow-a-model.md
    title: "Timely Dataflow: A Model"
    author: "Martín Abadi, Michael Isard"
---

# Многомерное логическое время Ariadne

`ari_vtime` хранит время как opaque-значение:

```erlang
{Time :: integer(), Iterations :: [non_neg_integer()]}
```

`Time` — базовая эпоха. `Iterations` — стек координат вложенных циклов; голова
списка относится к текущему, самому внутреннему циклу.

```erlang
ari_vtime:new(Time).
ari_vtime:ingress(Time).
ari_vtime:feedback(Time).
ari_vtime:egress(Time).
ari_vtime:le(Left, Right).
```

- `new/1` создаёт время вне циклов;
- `ingress/1` добавляет нулевую координату цикла;
- `feedback/1` увеличивает текущую координату цикла;
- `egress/1` удаляет текущую координату цикла;
- `le/2` задаёт покомпонентный частичный порядок.

`le/2` принимает времена одной глубины. Для `could-result-in` время источника
сначала преобразуется рёбрами пути к временному контексту назначения, а затем
сравнивается со временем назначения.

Базовая эпоха не обязана обозначать физическое время. Это может быть номер
эпохи или нормализованная временная метка. Часовой пояс относится к вводу и
отображению, а не к внутреннему представлению.
