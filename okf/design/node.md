---
type: Design
title: "Узел графа Ariadne"
description: "Контракт реализации узла графа."
status: draft
tags: [ariadne, node, timely-dataflow, design]
sources:
  - id: timely-dataflow-model
    resource: ../references/papers/timely-dataflow-a-model.md
    title: "Timely Dataflow: A Model"
    author: "Martín Abadi, Michael Isard"
---

# Узел графа Ariadne

```erlang
-include_lib("ariadne/include/ariadne.hrl").
```

`Module` из `node(Name, Module, Args)` реализует функции:

```erlang
input() ->
    [InputSlot].

output() ->
    [OutputSlot].

init(Args) ->
    {State, Notifications}.

handle_message(InputSlot, Message, Time, State) ->
    {NewState, Notifications, Outputs}.

handle_notification(Time, State) ->
    {NewState, Notifications, Outputs}.
```

Слоты статичны и проверяются при сборке runtime, до вызова `init/1`. `Args`
используются только для инициализации состояния.

- `InputSlot` и `OutputSlot` — атомы;
- `Message` — данные без времени;
- `Time` — время сообщения или уведомления;
- `Notifications` — запрошенные времена уведомлений;
- `Outputs` — список `{OutputSlot, Message, Time}`.

Время передаётся отдельно от сообщения. Функция `time(Message)` в API Ariadne не
нужна.
