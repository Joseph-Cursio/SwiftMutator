# Mutation Operators
SwiftMutator uses **mutation operators** to generate mutants in your source code. This is the list of currently available mutation operators.

No operator mutates the condition of a `#if` or `#elseif`. Such a mutant would change which branch compiles, and a branch written for another platform may not build, which would fail the build every mutant shares. This doesn't change what happens to the code inside the clauses.

## Relational Operator Replacement
The relational operator replacement operator, `RelationalOperatorReplacement`, will invert relational operators in your code based on this table:

Original Operator | Negated Operator
------------------|-----------------
`==`|`!=`
`!=`|`==`
`>=`|`<=`
`<=`|`>=`
`>`|`<`
`<`|`>`

The purpose of this operator is to highlight how your tests respond to changes in branching logic. A well-engineered test suite will be able to fail clearly in response to code taking a different branch than it expected.

### Mutating an equality check
```swift
if myValue == 50 {
    // something happens here
}
```

becomes

```swift
if myValue != 50 {
    // something happens here
}
```

## Relational Boundary
The relational boundary operator, `RelationalBoundary`, will move the boundary of an ordering comparison based on this table:

Original Operator | Changed Operator
------------------|-----------------
`<`|`<=`
`<=`|`<`
`>`|`>=`
`>=`|`>`

The purpose of this operator is to highlight whether your tests check the edge of each comparison. The relational operator replacement operator above turns `<` into `>`, which almost any test kills. Turning `<` into `<=` changes the result only at the boundary value, so the mutant survives unless some test uses that value. Equality operators have no boundary, so `==` and `!=` are left to the relational operator replacement operator. Each ordering operator gets a mutant from both operators, so a run has one more mutant for each `<`, `<=`, `>` and `>=` it mutates.

As with the relational operator replacement operator, only an operator in an expression is mutated: an operator's declaration, such as `static func < (lhs: Self, rhs: Self) -> Bool`, is not.

### Mutating a boundary
```swift
if count < 10 {
    // something happens here
}
```

becomes

```swift
if count <= 10 {
    // something happens here
}
```

## Change Logical Connector
The change logical connector operator will change conditional operators in your code based on this table:

Original Operator | Changed Operator
------------------|-----------------
`&&`|`\|\|`
`\|\|`|`&&`

The purpose of this operator is to highlight how your tests respond to changes in logic. A well-engineered test suite will be able to fail clearly in response to different logical constraints.

### Mutating a Logical AND
```swift
func isValidPassword(_ text: String, _ repeatedText: String) -> Bool {
    let meetsMinimumLength = text.count >= 8
    let passwordsMatch = repeatedText == text
    return meetsMinimumLength && passwordsMatch
}
```

becomes

```swift
func isValidPassword(_ text: String, _ repeatedText: String) -> Bool {
    let meetsMinimumLength = text.count >= 8
    let passwordsMatch = repeatedText == text
    return meetsMinimumLength || passwordsMatch
}
```

## Remove Side Effects 
The Remove Side Effects operator will remove code it determines is causing a side effect. It will determine your code is causing a side effect based on a few rules:

* A line contains a function call which is explicitly discarding a return result
* A line contains a function call and doesn't save the result of the function call into a named variable or constant (i.e. a line implicitly discards a return result or doesn't produce one)
* A line does not contain a call to `print`, `debugPrint`, `dump`, `NSLog`, `os_log`, `fatalError`, `preconditionFailure`, `precondition`, `assert`, `assertionFailure`, `dispatchPrecondition`, `exit`, `_exit`, `pthread_exit`, `abort`, or any function listed in `muter.conf.yml` under the `excludeCalls` key.

The purpose of this operator is to highlight how your tests respond to the absence of expected side effects.

A statement counts under `try`, `await` and `unsafe` too, so `try save()` is removed. It looks in the bodies of functions, initializers, `deinit`, accessors, closures, `for`, `while`, `repeat`, `if`, `else`, `switch` cases, `do`, `catch`, `guard` and `defer`.

### What it never removes

The calls above are matched by the called name, not by the statement's text. `print` keeps `print(x)` and `Swift.print(x)`, but not `printer.flush()`, `foo.print(x)` or a call under a comment that mentions print. A call anywhere in a statement keeps it, in an argument or a closure too, so `items.forEach { print($0) }` stays, as does a function passed by name, as in `items.forEach(print)`. An `excludeCalls` entry matches whole names in a call's path, on any value: `exit` keeps `editor.exit()`, `log` keeps `log.debug()` and `Logger.log()`, and `Logger.log` keeps `Logger.log()`, not `log()` or `Other.log()`. `log` doesn't keep `logger.debug()` or `DDLogInfo()`: name those.

It also keeps:

* `super.init(…)` and `self.init(…)`, as the code doesn't compile without them, `Task.yield()`, and `assertIsolated()`, `preconditionIsolated()` and `reserveCapacity(_:)` on any value.
* Calls on a lock, which can leave a thread waiting until the time limit: a value in the same file declared, made or given as a `DispatchSemaphore`, `DispatchGroup`, `NSLock`, `NSRecursiveLock`, `NSCondition`, `NSConditionLock` or `OSAllocatedUnfairLock`, `lock()`, `unlock()` and `tryLock()` on any value, `os_unfair_lock_*` and `pthread_mutex_*`, `pthread_rwlock_*` and `pthread_cond_*`, and `resume` on a value with `continuation` in its name. `withLock` is removed, as it takes its body with it, and `Mutex` has no other call to remove. A lock the syntax can't name is missed, as in a tuple, an array or behind `as!`: its mutant can run to the time limit.
* What the code needs in order to compile: the last statement of a `guard` body, or of a function, getter or closure that returns a value, by its type or a `return` with a value in it, as it may be a call that never returns, through an `if`, `switch` or `do` that ends the body too; every branch of an `if` or `switch` used as a value; the only statement of a builder function or a closure with no written type, as it may be the value, and of an initializer, `_read` or `_modify`, as it may stand in for what those must do. A closure's only statement is removed where the call is known to ignore its value, when the call's own value isn't used: `forEach`, `Task`, `Task.detached`, `async`, `asyncAfter`, `sync`, `withLock`, `withTaskCancellationHandler`, `withExtendedLifetime` and `Button`.
* `Text("a").font(.x)`, `Spacer()` and other chains that start by calling a capitalized name, other than `Task`, in a closure, a getter or a builder function, directly or in an `if` or `case` there. They make a value for a result builder, as far as the syntax can tell. Elsewhere, as in a loop in that closure, they are removed.
* The statements directly in a `#if` clause, which may be a value's only ones, a list in a macro's arguments, and the statements of a function or getter that returns `some` and isn't a result builder, which would lose the mutants of the lists in it.

Syntax can't tell every statement a build needs, as a call to your own `Never` function that a later `let` depends on, or that ends a closure only its context gives a type. Such a mutant [is left out when the build fails](../README.md#mutants-that-dont-compile).

Removing a line from a `while` or `repeat` body can make the loop endless, as removing `directories.removeLast()` from `while !directories.isEmpty` does. The mutant is then stopped at its time limit and ends as a timeout, which the score counts as a survivor, unless the log already shows a failed test or a crash. These mutants are kept, as there's no telling them from the rest: on SwiftProjectLint, 5 of the 36 in such bodies timed out, while a rule that skips a call whose receiver is in the loop's condition would have caught at most 3 of those 5 and dropped 10 others, 8 of which tests killed.

### Mutating an explicitly discarded return result

```swift
func initialize() {
    _ = self.view
    view.results = self.results
}
```

becomes

```swift
func initialize() {
    view.results = self.results
}
```


### Mutating a void function call

```swift
func update(email: String, for userId: String) {
    var userRecord = record(for: userId)
    userRecord.email = email
    database.persist(userRecord)
}
```

becomes

```swift
func update(email: String, for userId: String) {
    var userRecord = record(for: userId)
    userRecord.email = email
}
```

## Swap Ternary

The Swap Ternary operator will swap ternary operators in your code based on this table:

| Original Operator                             | Changed Operator                              |
| --------------------------------------------- | --------------------------------------------- |
| `<condition> ? <expression1> : <expression2>` | `<condition> ? <expression2> : <expression1>` |

The purpose of this operator is to highlight how your tests respond to changes in logic. A well-engineered test suite will be able to fail clearly in response to different logical constraints.

Each link of a chain gets a mutant of its own: `a ? b : c ? d : e` gets `a ? c ? d : e : b` and `a ? b : c ? e : d`.

Some ternaries are left alone:

* **One whose two branches are the same code,** as in `c ? x : x`, whatever their spacing or comments. No test could tell the mutant from the original.
* **One with an `as` cast among the terms of its expression,** as in `a ? 1 : 2 as Int`. A cast in parentheses or in the first branch doesn't count.
* **One followed by an assignment in the same expression,** as an assignment binds more loosely than `?:`.

## Negate Conditional

The negate conditional operator, `NegateConditional`, will wrap each expression condition of an `if`, `guard` or `while` in `!( )`. Each condition of a list gets a mutant of its own: `if a, b` gets `if !(a), b` and `if a, !(b)`.

The purpose of this operator is to highlight whether your tests tell the two branches apart. Unlike the relational operator replacement operator, it covers conditions with no comparison in them, such as `if isValid`, and it treats a condition as a whole, so `if isValid && !isEmpty` becomes `if !(isValid && !isEmpty)`.

Some conditions are left alone:

* **Conditions that aren't expressions:** `if let`, `case` and `#available`. An expression beside one in the list still gets its mutant, so `if let value, value.isReady` becomes `if let value, !(value.isReady)`.
* **The literals `true` and `false`.** To the compiler `while true` never ends, so a function can end without a `return` after it. Negated, the loop can end, and the function no longer compiles.
* **A condition that is one `==` or `!=` comparison, while `RelationalOperatorReplacement` is on.** `!(a % 2 == 0)` is the same mutant as that operator's `a % 2 != 0`, so it isn't tested twice. `a == b && c` isn't one. `!(a < b)` is `a >= b`, where that operator gives `a > b`, so ordering comparisons get both. `===` and `!==` are negated, as no other operator changes them.
* **`#_hasSymbol`,** which can only be a condition itself, and a condition that ends in `#endif`, which nothing can follow on its line.

The condition of `repeat`-`while`, a ternary and a `case`'s `where` aren't mutated.

A negated `while` condition can loop forever. The mutant is then stopped at its time limit and ends as a timeout, which the score counts as a survivor, unless the log already shows a failed test or a crash. With several workers it is [run again](../README.md#timeouts-are-run-again), at the cost of a second limit.

A few negated conditions don't compile, and are [left out as build errors](../README.md#mutants-that-dont-compile), at the cost of a rebuild:

* A condition the compiler works out, as in `let running = true; while running { ... }` with no code after the loop. Only the literals are recognized.
* A condition whose type came from `if`, when the module declares a `!` of its own: `if .random()` can then be ambiguous.

### Mutating a condition
```swift
if isValid && !isEmpty {
    // something happens here
}
```

becomes

```swift
if !(isValid && !isEmpty) {
    // something happens here
}
```

## Change Arithmetic Operator

The `ChangeArithmeticOperator` operator will change arithmetic operators in your code based on this table:

Original Operator | Changed Operator
------------------|-----------------
`+`|`-`
`-`|`+`
`*`|`/`
`/`|`*`
`%`|`*`

Their assignment forms, `+=`, `-=`, `*=`, `/=` and `%=`, change in the same way.

The purpose of this operator is to highlight whether your tests check the value a calculation gives.

Only an operator in an expression is mutated: not an operator's declaration, nor `+` passed as a function in `reduce(0, +)`. The wrapping operators, such as `&+`, a prefix `-` and the shifts aren't mutated.

`+` and `+=` get a mutant only with a sign that their operands are numbers, as they also join strings and arrays, which `-` can't take apart, and a syntax tree has no types. On SwiftProjectLint, a mutant for every `+` failed to compile often enough to reach a run's limit of failed builds, which stops the run. The sign can be, in the same run of arithmetic:

* A numeric literal, as in `index + 1` or `count += 1`.
* A name that counts something: `items.count`, `count` or `lineCount`.
* A negative number, as in `a + -b`.
* An arithmetic operator other than `+` and `+=`, as in `a * b + c` or `a - b + c`.

Any other operator, an assignment, a cast or a ternary ends the run, so the `1` of `a + b == 1` is no sign, nor is the `1` of `"item" + (n == 1 ? "" : "s")`. As `+=` takes all that follows, what follows it is a sign only if the run reaches the end. So `price + tax` isn't mutated, though `price - tax` is.

Some other operators are left alone:

* **One that changes nothing:** `x + 0`, `x - 0`, `x * 1`, `x / 1`, `x * -1`, `x / -1`, and their assignment forms, whose mutants give the same value. `0 + x` and `1 * x` are mutated, as `0 - x` and `1 / x` differ.
* **`x * 0` with an integer literal,** as dividing an integer by a literal zero doesn't compile. `x * 0.0` is mutated.
* **One in a run with a string or array literal,** as in `"Total: " + count` or `dir / name + ".swift"`, as those aren't numbers. A literal inside a call doesn't count, so the `+` of `g("a") + 1` is mutated.
* **A `*` touching a comment,** as in `a */* why */ b`, which as `/` would start a line comment.

A few of these mutants don't compile, and are [left out as build errors](../README.md#mutants-that-dont-compile), at the cost of a rebuild:

* A `*` of values that have no `/`, such as a `Numeric` generic, and a type's own `/`, such as a path's.
* A `+` whose sign misleads, as in `name + displayCount` between two strings.
* A `-` that takes values `+` can't, as `a - b` between two `ContinuousClock.Instant`s.
* Literals that overflow once changed, as in `let a: UInt = 1 + 2`, and a bound pushed past itself, as `Int.max - 1` becoming `Int.max + 1` or `Int.max / 2` becoming `Int.max * 2`.

A mutant that compiles can stop the tests instead: subtracting can overflow, and dividing can divide by zero. Either crash counts as killing the mutant.

### Mutating a calculation
```swift
let next = index + 1
```

becomes

```swift
let next = index - 1
```

## Flip Boolean Literal

The flip boolean literal operator, `FlipBooleanLiteral`, will turn `true` into `false` and `false` into `true`, in a value, an argument, a default argument or a `return`.

The purpose of this operator is to highlight whether your tests check the values your code gives and is given.

Some literals are left alone:

* **A literal that is a whole condition,** as in `while true`, `if true` or `repeat { ... } while true`, with or without parentheses. To the compiler `while true` never ends and `if true` is always taken, so the code after them can go without a `return` or a value it needs. Flipped, it no longer compiles. Nor does such a literal test anything.
* **A literal in a pattern,** as in `case true:`, `case (true, _):`, `case .on(false):` or `if case true = value`. Flipping one in a `switch` usually leaves it not exhaustive. What a `case` runs and its `where` clause are mutated.

A few flipped literals don't compile, and are [left out as build errors](../README.md#mutants-that-dont-compile), at the cost of a rebuild and sometimes of the function's other mutants: one the compiler sees through to treat a loop as endless or a branch as always taken, as in `while !false`, `if !false` or `let running = true; while running {}`.

`x == true` gets a mutant here and another from `RelationalOperatorReplacement`, as `x == false` and `x != true` differ when `x` is an optional.

### Mutating a literal
```swift
return true
```

becomes

```swift
return false
```

## What each operator catches and costs

SwiftMutator has no tiers of operators: all eight run by default, and `--operators`, `--skip-operators` and the `operators` and `skipOperators` keys narrow a run. These numbers, from each run's `results.jsonl`, are why. Killed and survived are shares of the mutants tested, so they leave out build errors.

Operator | SwiftProjectLint: mutants | Killed | Survived | Timed out | Build errors | SwiftCloneDetector: mutants | Killed | Survived | Timed out | Build errors
---------|-----|-----|-----|---|---|-----|-----|-----|---|---
`NegateConditional` | 122 | 89% | 9% | 2 | 0 | 90 | 92% | 8% | 0 | 0
`RelationalOperatorReplacement` | 185 | 86% | 13% | 1 | 0 | 115 | 77% | 22% | 1 | 0
`RemoveSideEffects` | 300 | 78% | 21% | 4 | 0 | 94 | 76% | 24% | 0 | 0
`FlipBooleanLiteral` | 1335 | 79% | 20% | 6 | 0 | 25 | 72% | 28% | 0 | 0
`SwapTernary` | 19 | 79% | 21% | 0 | 0 | 23 | 52% | 48% | 0 | 0
`ChangeArithmeticOperator` | 217 | 61% | 35% | 8 | 1 | 53 | 68% | 30% | 1 | 0
`ChangeLogicalConnector` | 51 | 61% | 39% | 0 | 0 | 27 | 63% | 37% | 0 | 0
`RelationalBoundary` | 29 | 48% | 52% | 0 | 0 | 88 | 35% | 65% | 0 | 0

Measured on 5 November 2026, on SwiftProjectLint `76fcfca9` at 4 workers and SwiftCloneDetector `e03e865` with all eight. On SwiftProjectLint, the two new operators ran in full, and the six older ones as a random sample of 500 of their 5,534 mutants, so their counts there are small. `FlipBooleanLiteral`'s run there came before the last changes to `ChangeArithmeticOperator`, which don't touch its mutants: four plans since find the same ones, but for up to 2 fewer or 1 more as coverage runs reach a little more or less of the project. `RemoveSideEffects` was measured again on 6 November, once it looked in more blocks: a random sample of 300 of its 1,712 mutants on SwiftProjectLint, and all 94 on SwiftCloneDetector.

* **Nearly every mutant builds.** 1 of these 2,773 mutants was a build error. On its own five projects, swift-mutation-testing counts 12.1% of its arithmetic mutants and 11.5% of its boolean-literal ones as unviable, and it keeps both out of its default tier. Its rules and its projects differ, so the figures aren't like for like.
* **Kill rates don't sort the operators into tiers.** `SwapTernary` is 79% on one project and 52% on the other, a wider gap than between most operators. `ChangeLogicalConnector` and `SwapTernary` are in swift-mutation-testing's default tier, yet here they score level with or below `RelationalOperatorReplacement` and `RemoveSideEffects`, which aren't. A low rate can also be an operator doing its job: a `RelationalBoundary` mutant survives unless a test checks the edge value.
* **Survivors can cluster.** 55 of `ChangeArithmeticOperator`'s 76 survivors on SwiftProjectLint track a depth: a recursive call's `depth + 1`, or a counter such as `typeNestingDepth -= 1`.
* **The cost differs more than the catch.** `FlipBooleanLiteral` gave 1,335 mutants on one project and 25 on the other. The two new operators together added 28% to SwiftProjectLint's mutants and 20% to SwiftCloneDetector's, before `RemoveSideEffects` grew. On SwiftProjectLint a mutant took 8.6 s on average under the six older operators, 9.4 s under `FlipBooleanLiteral` and 14.1 s under `ChangeArithmeticOperator`.
* **More blocks found more.** Looking in more kinds of block took `RemoveSideEffects` from 995 mutants to 1,839 on SwiftProjectLint, and from 46 to 97 on SwiftCloneDetector, before coverage leaves out code the tests never ran. On SwiftProjectLint, of 116 new mutants sampled, 83% were killed, 16% survived and 1 timed out, against 75%, 23% and 3 of the 184 older ones. On SwiftCloneDetector the new ones did worse than the older ones, at 63% killed against 89%, and none timed out.
* **Arithmetic times out most.** On SwiftProjectLint 3.7% of its mutants timed out, against 0.8% for the six older operators in that run and 0.4% for `FlipBooleanLiteral`. All 8 were `+=` or `-=`, as in `index += 1`, and running them again took 14 of that 32-minute run's minutes.

A project that finds an operator too costly can turn it off, as with `skipOperators: [FlipBooleanLiteral]`. Two projects are few, and numbers from more could change this.
