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
  - id: naiad
    resource: "https://www.cs.princeton.edu/courses/archive/fall22/cos418/papers/naiad.pdf"
    title: "Naiad: A Timely Dataflow System"
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
- `le/2` сравнивает эпохи обычным `=<`, а векторы итераций — лексикографически
  от внешнего цикла к внутреннему; оба условия должны выполняться.

Это порядок времени из раздела 2.1
[статьи о Naiad](https://www.cs.princeton.edu/courses/archive/fall22/cos418/papers/naiad.pdf#page=3).
Стек хранится внутренней координатой вперёд, поэтому при сравнении приоритет
имеют координаты в конце списка. Например, `{5, [3, 0]} =< {5, [0, 1]}`:
внешняя итерация выросла, а внутренний счётчик начал отсчёт заново.

Общий порядок частичный: `{5, [1]}` и `{6, [0]}` несравнимы, поскольку эпоха
и вектор итераций изменились в противоположных направлениях.

`le/2` принимает времена одной глубины. Для `could-result-in` время источника
сначала преобразуется рёбрами пути к временному контексту назначения, а затем
сравнивается со временем назначения.

Базовая эпоха не обязана обозначать физическое время. Это может быть номер
эпохи или нормализованная временная метка. Часовой пояс относится к вводу и
отображению, а не к внутреннему представлению.

## Сводки путей

`ari_vtime` также хранит сводки путей — композиции преобразований рёбер в
нормальной форме «снять, увеличить, добавить»:

```erlang
ari_vtime:summary(Kind).
ari_vtime:summary(Pop, Bump, Push).
ari_vtime:transfer(Summary, Time).
ari_vtime:compose(First, Second).
ari_vtime:dominates(Left, Right).
```

- `summary/1` даёт сводку одного ребра вида `message`, `ingress`, `feedback`
  или `egress`;
- `summary/3` собирает сводку из компонентов;
- `transfer/2` переносит время по пути;
- `compose/2` соединяет путь с его продолжением;
- `dominates/2` истинно, когда левая сводка даёт время не больше правой на
  любом входе; сравнимы только сводки с равным `Pop` и равной длиной `Push`.

Нормальная форма, композиция и роль сводок в проверке прогресса описаны в
разделе «Достижимость и `could-result-in`»
[локального runtime](local-runtime.md#достижимость-и-could-result-in).
