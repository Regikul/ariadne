---
type: Design
title: "DSL описания графа Ariadne"
description: "Минимальный декларативный язык для задания узлов, внутренних рёбер и входных/выходных полурёбер timely dataflow-графа."
status: draft
tags: [ariadne, graph, dsl, timely-dataflow, design]
sources:
  - id: timely-dataflow-model
    resource: ../references/papers/timely-dataflow-a-model.md
    title: "Timely Dataflow: A Model"
    author: "Martín Abadi, Michael Isard"
---

# DSL описания графа Ariadne

DSL задаёт узлы, внутренние рёбра и входные/выходные полурёбра графа.

```erlang
#node{name, module, args}
#edge{name, from, to}
#ingress{name, loop, from, to}
#egress{name, loop, from, to}
#feedback{name, loop, from, to}
#loop{name, items}
#graph{nodes, edges}
```

У входного полуребра `from = undefined`, у выходного `to = undefined`.
`#loop.items` хранит сырой список узлов и рёбер. `graph/1` раскрывает циклы и
возвращает плоские списки узлов и рёбер; `#loop{}` в результат не входит.

## Синтаксис

```erlang
graph([
    node(A, ModuleA, ArgsA),
    node(B, ModuleB, ArgsB),

    in(Input, {A, InputSlotA}),
    edge(AtoB, {A, OutputSlotA}, {B, InputSlotB}),
    out(Output, {B, OutputSlotB})
]).
```

| Конструкция | Значение |
| --- | --- |
| `graph(Items)` | описание графа |
| `node(Name, Module, Args)` | узел и его реализация |
| `in(Name, {Node, InputSlot})` | входное полуребро без источника |
| `edge(Name, {FromNode, OutputSlot}, {ToNode, InputSlot})` | внутреннее ребро |
| `out(Name, {Node, OutputSlot})` | выходное полуребро без назначения |
| `loop(Name, Items)` | контекст цикла с вложенным списком элементов |
| `feedback(Name, {FromNode, OutputSlot}, {ToNode, InputSlot})` | обратное ребро цикла |

## Композиция

Полурёбра сопоставляются по имени. Если первый граф содержит:

```erlang
out(Data, {A, OutputSlot})
```

а второй:

```erlang
in(Data, {B, InputSlot})
```

то в объединённом графе они образуют:

```erlang
edge(Data, {A, OutputSlot}, {B, InputSlot})
```

Несопоставленные `in` и `out` остаются внешними полурёбрами объединённого графа.
Соединение может происходить в обоих направлениях между двумя графами.

## Циклы

```erlang
graph([
    node(Source, SourceModule, SourceArgs),
    out(Input, {Source, OutputSlot}),

    loop(Iteration, [
        node(A, ModuleA, ArgsA),
        node(B, ModuleB, ArgsB),
        in(Input, {A, InputSlotA}),
        edge(AtoB, {A, OutputSlotA}, {B, InputSlotB}),
        feedback(Next, {B, FeedbackOutput}, {A, FeedbackInput}),
        out(Output, {B, OutputSlotB})
    ]),

    node(Sink, SinkModule, SinkArgs),
    in(Output, {Sink, InputSlot})
]).
```

`in` цикла соединяется с одноимённым `out` родительского контекста, а `out`
цикла — с одноимённым `in` родительского контекста. Несовпавшее полуребро цикла
является ошибкой.

При сборке первая пара преобразуется в `#ingress{}`, вторая — в
`#egress{}`. Эти специальные рёбра сообщают runtime, где нужно войти во
временной контекст цикла и выйти из него. `#feedback{}` сообщает runtime, где
нужно перейти к следующей итерации. Поле `loop` связывает каждое специальное
ребро с временным контекстом цикла. Узлы этих преобразований не выполняют.

`ingress` и `egress` выводятся из границ `loop` автоматически. `feedback`
задаётся явно и относится к непосредственно содержащему его циклу.

Ацикличность проверяется отдельно в каждом контексте: в корневом графе и внутри
каждого `loop`. При проверке непосредственно вложенный цикл считается одной
вершиной, а связи через его входы и выходы — рёбрами этой вершины. Исключаются
только feedback-рёбра проверяемого контекста. Полученный граф должен быть
ацикличным.

Поэтому путь, выходящий из вложенного цикла и возвращающийся в него, должен
проходить через feedback внешнего контекста. Если такого контекста ещё нет,
повторяемую часть графа нужно обернуть во внешний `loop`. Feedback внутри
вложенного цикла не разрешает циклическую связь снаружи него.

После раскрытия всех циклов дополнительно проверяется ацикличность плоского
графа без feedback-рёбер.

## Правила

- имена узлов уникальны;
- имена всех рёбер уникальны;
- каждый конец ребра ссылается на объявленный узел;
- концы внутреннего ребра принадлежат разным узлам, как требует статья;
- порядок объявлений значения не имеет;
- несколько рёбер между одной парой узлов разрешены;
- циклы объявляются через `loop`, обратные рёбра — через `feedback`;
- каждый контекст ацикличен после свёртки непосредственно вложенных циклов в
  вершины и исключения собственных feedback-рёбер.

Соответствие слотов функциям `input/0` и `output/0` проверяется позднее, при
сборке runtime.

## Соответствие статье

`node`, `in`, `edge` и `out` соответствуют узлам, входным, внутренним и выходным
рёбрам из [раздела 2.1](../references/papers/timely-dataflow-a-model.md#21-basics-of-graphs-messages-and-times).

## Открытые вопросы

- допустимые типы `Name`;
- способ подключения функций DSL в Erlang-модуль;
- правила множественного подключения слотов;
- форма вызова композиции и разрешение конфликтов имён узлов;
- операции временного домена для ingress, egress и feedback.
