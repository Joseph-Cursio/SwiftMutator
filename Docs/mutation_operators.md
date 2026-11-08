# Mutation Operators
SwiftMutator uses **mutation operators** to generate mutants in your source code. This is the list of currently available mutation operators.

No operator mutates the condition of a `#if` or `#elseif`. Such a mutant would change which branch compiles, and a branch written for another platform may not build, which would fail the build every mutant shares. This doesn't change what happens to the code inside the clauses.

## Relational Operator Replacement
The relational operator replacement operator, `RelationalOperatorReplacement`, gives each comparison the mutants of Kaminski, Ammann and Offutt's sufficient set ("Better Predicate Testing", 2011), based on this table:

Original | Swapped to | Constant
---------|------------|---------
`<` | `!=` | `false`
`<=` | `==` | `true`
`>` | `!=` | `false`
`>=` | `==` | `true`
`==` | | `true`, and `false`
`!=` | | `false`, and `true`

So an ordering comparison gets two mutants, its operator swapped and the comparison replaced with a constant, and an equality check gets two, the comparison replaced with each constant, except that a loop's condition gets no constant that would keep the loop going (see below). `===` and `!==` are left alone.

The purpose of this operator is to highlight whether your tests see each comparison both true and false, and check the values on either side of it.

A comparison operator can be replaced with any of the others, or the comparison with `true` or `false`, which makes seven mutants of each. Kaminski, Ammann and Offutt showed that three of them are enough: tests that kill those three kill the other four. Each of the four gives the same result as one of the three wherever that one is wrong, so a test that kills that one kills it too. For `a < b`, the three are `a <= b`, which is wrong only where `a == b`; `a != b`, wrong only where `a > b`; and `false`, wrong only where `a < b`. Between them they ask for a test of each of the three ways `a` and `b` can stand. [`RelationalBoundary`](#relational-boundary) gives the first, and this operator the other two. The reversal this operator gave before, `a > b`, is wrong where `a != b` is and where `false` is, giving the same results, and nowhere else, so it tells nothing they don't, and almost any test kills it.

For `a == b`, the paper's three are `a <= b`, `a >= b` and `false`. `<=` and `>=` don't compile where the type is only `Equatable`, and a syntax tree has no types, so an equality check gets both constants instead: `false` is wrong only where `a == b`, and `true` only where `a != b`, so together they ask for a test where the two are equal and one where they differ. The swap this operator gave before, `a != b`, is wrong everywhere, and gives the same result as either constant wherever that one is wrong, so a test that kills either kills it. The pair doesn't cover the paper's `a <= b` and `a >= b`, which also ask which side of `b` an `a` that differs is on.

These are every mutant of `a < b` and `a == b`:

Mutant of `a < b` | Operator | Differs from it when
------------------|----------|---------------------
`a <= b` | [`RelationalBoundary`](#relational-boundary) | `a == b`
`a != b` | `RelationalOperatorReplacement` | `a > b`
`false` | `RelationalOperatorReplacement` | `a < b`

Mutant of `a == b` | Operator | Differs from it when
-------------------|----------|---------------------
`false` | `RelationalOperatorReplacement` | `a == b`
`true` | `RelationalOperatorReplacement` | `a != b`

The constants stand for the comparison's negation too, which is why [`NegateConditional`](#negate-conditional) leaves a condition that is one comparison to this operator, and [`ReplaceBooleanValue`](#replace-boolean-value) a value that is one. `!(a < b)` gives the same result as `false` wherever `false` is wrong: both are false where `a < b` is true. So a test that kills `false` kills the negation, which is otherwise wrong where `a >= b` too, and almost any test kills it. And `true`, which `ReplaceBooleanValue` would put in place of `a < b`, gives the same result as `a <= b` where that one is wrong, at `a == b`, and as `a != b` where that one is wrong, so a test that kills either kills it. A floating-point NaN, which the boundary mutant used to leave to the negation, changes none of this: where `a < b` is true, neither is a NaN, and with one, `a != b` gives `true`, as the `true` constant does.

A constant replaces the whole comparison, as the standard library's operators bind: `a + 1 < b` becomes `false`, and `x < y && z` becomes `false && z`. A `try` or `await` in front goes with it when it covers the comparison alone, as in `try load() < 1`; in front of more, as in `try load() < 1 && check()`, it stays, as `try false && check()`, since `check()` may throw. A comment beside the comparison stays where it was. The `true` mutant is placed where the comparison starts, the `false` one where it ends, and the swap at the operator, so each has a place, and a switch, of its own, and `--mutant` can name any of them with the operator: `--mutant` also finds `NegateConditional`'s and `ReplaceBooleanValue`'s mutants of the comparison, which start or end where a constant does, so a place alone may name two and be refused with both listed.

Some comparisons get no constant, and their operator is swapped instead, `==` to `!=` and `!=` to `==` too:

* **A comparison that is a statement of its own,** as Nimble's `expect(x) == 1` is. Its value is thrown away, so its operator is an overload with side effects, and a literal in its place would be an unused value that tests nothing. The one statement of a closure, a getter, a function that writes its return type, or a branch of an `if` or `switch` that is a value is that code's value, and gets its constants.
* **A comparison in a sequence the standard library's operators can't fold,** as one with an operator of the project's own precedence, `a <~> b == c`, is. Which part of the sequence is the comparison isn't known.
* **A comparison that holds a closure's only use of its highest `$` argument,** as in `items.filter { $0 > 1 }`. A closure that names no parameters takes as many as the highest `$` argument it uses says, so `items.filter { false }` takes none, which doesn't compile. `items.filter { item in item > 1 }` gets its constant.

A comparison that decides the condition of a `while` or `repeat`-`while`, alone or through `||`, `!` and parentheses, gets no constant that makes that condition always true: `while a <= b` keeps only its swap, `while a != b` and `repeat { ... } while a == b` only `false`, and `while !(a < b)` only its swap. `while true` would run until the time limit and end as a timeout, which the score counts as a survivor, and with several workers is [run again](../README.md#timeouts-are-run-again). What is left is wrong only where the negation is too, so `NegateConditional` still leaves such a condition to this operator. Through `&&`, or beside another condition after a comma, the rest of the condition can still end the loop, and both constants are kept, as they are in an `if` or `guard`.

Only an operator in an expression is mutated: an operator's declaration, such as `static func < (lhs: Self, rhs: Self) -> Bool`, and a generic constraint, such as `where T == Int`, are not. A `muter:disable` comment that leaves out any of a comparison's mutants leaves out all of them, as it does both of [`ReplaceBooleanValue`](#replace-boolean-value)'s.

A few of these mutants don't compile, and are [left out as build errors](../README.md#mutants-that-dont-compile), at the cost of a rebuild:

* A comparison that a module declares to give something other than a Bool, as a query builder's `Column("age") >= 18` or a predicate DSL's does. Neither `true` nor `false` is such a value. A statement of its own, as an assertion library's, is left to the swap, as above.
* A swap to `!=` or `==` of a type that declares `<` but isn't `Equatable`.

Some make the compiler warn, which is a build error only [with warnings as errors](../README.md#before-a-long-run), as [`ReplaceBooleanValue`](#replace-boolean-value)'s do: a local whose only reader was the comparison, which is now never used; a `try` left over `false && check()` where `check()` doesn't throw, or a `try?` over the comparison alone; a closure whose only use of a captured name, as `self` in `[weak self]`, was the comparison; and a local `let` that is now `true` or `false`, or a ternary of literals on one, read later by an `if`, `guard`, `while`, `switch` or `?:`, whose other branch the compiler says will never be executed. A literal written as a condition, as `if false`, makes it say nothing.

### Mutating an equality check
```swift
if myValue == 50 {
    // something happens here
}
```

becomes

```swift
if true {
    // something happens here
}
```

and

```swift
if false {
    // something happens here
}
```

### Mutating an ordering comparison
```swift
return count < limit
```

becomes

```swift
return count != limit
```

and

```swift
return false
```

## Relational Boundary
The relational boundary operator, `RelationalBoundary`, will move the boundary of an ordering comparison based on this table:

Original Operator | Changed Operator
------------------|-----------------
`<`|`<=`
`<=`|`<`
`>`|`>=`
`>=`|`>`

The purpose of this operator is to highlight whether your tests check the edge of each comparison. Turning `<` into `<=` changes the result only at the boundary value, so the mutant survives unless some test uses that value. It is the third of Kaminski, Ammann and Offutt's sufficient set for an ordering comparison, beside the relational operator replacement operator's two (see [above](#relational-operator-replacement)). Equality operators have no boundary, so `==` and `!=` are left to the relational operator replacement operator. Each ordering operator gets a mutant from this operator and two from that one, so a run has three for each `<`, `<=`, `>` and `>=` it mutates.

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
* A line contains a function call and doesn't save the result of the function call into a named variable or constant (i.e. a line implicitly discards a return result or doesn't produce one), under `try` or `await` or not
* A line is in a body: a function's, an initializer's or a deinitializer's, an accessor's, a closure's, a loop's, a `guard`, `do`, `catch`, `if`, `else` or `defer` body, or a `switch` case, but not a file's top level or a `#if` clause
* A line does not contain a call to `print`, `debugPrint`, `fatalError`, `preconditionFailure`, `precondition`, `assert`, `assertionFailure`, `exit`, `abort`, `super.init`, `self.init`, a call that takes or releases a lock, or a call to any function listed in `muter.conf.yml` under the `excludeCalls` key.
* A line is not the last of code whose end control must never reach: a `guard` body, a function or getter that returns a value, `Never` included, or a `do`, `catch`, `if` or `else` branch, `switch` case or `#if` clause that ends one of those.
* A line is not one whose removal would leave code that doesn't build, as the paragraphs below say: the value of its code, a part of a result builder, or the last line that definite initialization may rely on.

The purpose of this operator is to highlight how your tests respond to the absence of expected side effects.

A call is matched by the name it is called by, not by the line's text. `print` matches `print(…)`, `Swift.print(…)` and `self.print(…)`: the name alone, or after `self.`, `Self.`, `super.` or a capitalised module or type. It matches neither `printer.print(…)` nor `printer.flush()`, and a comment that mentions print plays no part. To match a method of a value, name the value as the code does: `logger.debug` matches `logger.debug(…)`, `self.logger.debug(…)` and `logger?.debug(…)`, as `?` and `!` play no part. A line is kept if any call in it matches, as `items.forEach { print($0) }` is, or if it passes a function that matches by name, as `events.forEach(log)` and `events.forEach(log(_:))` do with `log` in `excludeCalls`.

The assertions are on the list because tests rarely take their failing path, so removing one nearly always survives. An initializer that delegates must call `super.init` or `self.init`.

A case that a removal leaves empty gets `do {}`, which does nothing, as `break` would, and unlike `break` builds in a result builder too.

The one line of a closure whose return type isn't written or isn't `Void`, of a getter, or of a function that returns a value, is kept, as it may be that code's value: `transform($0)` is `items.map { transform($0) }`'s, and `items.map { }` doesn't compile. So the one line of `items.forEach { reset($0) }` is kept too, as the closure's type can't be told from the code. A branch of an `if` or `switch` that is a value, as in `let size = switch kind { … }`, or that is the one line of such code, loses no line at all, even one before a `throw`: the mutant's switch around a branch's lines makes an `if` statement of it, which has no value. Such an `if` or `switch` has an `else` all the way down, and each of its branches is one line or ends in `throw`; one with a branch of several lines that doesn't is a statement, and its branches lose their calls.

In code that may be a result builder's, a line that makes a value of a type, as `Text("a")`, `Text("a").bold()`, `WindowGroup { … }` or `CharacterClass.anyOf(",;")`, is a part of the builder's value, not a side effect, and is kept: a call of a type, of a module's type, or of a type's member, but not a method of a value a type holds, as `NotificationCenter.default.post(…)`. `Task { … }` is still removed. Code that may be a builder's is a closure whose type isn't written and that returns no value, or a getter or function marked `@…Builder` or of a `some` type, without a `return` of a value. Nothing is removed from a builder that takes no `if`, where no mutant's switch builds: a body of type `some Scene`, `some Widget` or `some RegexComponent`, one marked `@SceneBuilder`, `@WidgetBundleBuilder`, `@AppShortcutsBuilder` or `@RegexComponentBuilder`, an `appShortcuts` getter, a closure passed to a RegexBuilder type such as `Regex`, `Capture` or `OneOrMore`, or to `wholeMatch`, `firstMatch` and the other string methods that take one but `contains`, `split` and `starts`, and a `Group` among such a builder's parts. Another builder without `buildEither`, such as a project's own, fails the build when a removal there is switched, and the build then leaves the mutant out (see [Mutants that don't compile](../README.md#mutants-that-dont-compile)).

A call that never returns can also be what definite initialization relies on: in `let data: Data` followed by `do { data = try load() } catch { die() }`, removing `die()` leaves `data` unset where it's used. So the last line of an `if` or `else` body, a case or a `catch` body is kept in an initializer, or after a variable or constant declared without a value in the code around it, and so is an initializer's own last line, which may be `usage()` after an `if` that sets a property and returns.

Only a call that never returns can end a `guard` body or a function that returns a value, such as a project's own `usage()`, which the list can't name. Removing it leaves a body that falls through, which doesn't compile, and fails the build that every mutant shares. So the last line is kept, but for a declaration of a local function or type after it, and the lines before it are still removed. A `#if` after it is skipped too, as it may end the code in one build and not in another: on macOS, `#if os(Linux) flush() #endif` after `usage()` holds nothing. That holds for a getter, a closure that returns a value, as its written return type, a variable's function type, a call where it's written for its value, or a `return` of a value in it says, and a `do`, `catch`, `if` or `else` branch, `switch` case or `#if` clause that ends any of those. A result builder's body is the exception, as each of its lines is a part of its value. It's taken to be one when its function, property or subscript is marked with an attribute whose name ends in `Builder`, or is of a `some` type, as a protocol makes `View`'s `body` and `ViewModifier`'s `body(content:)` builders without a mark. So a function of a `some` type that isn't a builder loses no line. Two such lines are still removed, and the build then leaves them out (see [Mutants that don't compile](../README.md#mutants-that-dont-compile)): one that ends a closure whose code doesn't say it returns a value, though where it's passed does, and one that ends a `repeat` body that ends such code.

The lock calls are those on a variable, property or parameter of the file that holds a `DispatchSemaphore`, `DispatchGroup`, `NSLock`, `NSRecursiveLock`, `NSCondition`, `NSConditionLock` or `OSAllocatedUnfairLock`, made by its initializer or declared with its type, optional or generic, wherever in the file it's declared, and called, or passed by name, as `group.leave` is to `queue.async(execute:)` (only a method that takes, releases or waits for the lock counts then, so passing `lock.name` doesn't), alone or after `self.`, `Self.` or its type; and calls to `os_unfair_lock_lock`, `os_unfair_lock_unlock`, `pthread_mutex_lock` and `pthread_mutex_unlock`. Removing one can leave a later call waiting for good, which ends as a timeout. `withLock` isn't one: removing it removes the work in it, but leaves no lock taken, which is why `Mutex`, used only through it, isn't on the list either. Locks are known by name, so a call on another value of the same name in the file is kept too, and a lock declared in another file isn't known.

Removing a line from a `while` or `repeat` body can make the loop endless, as removing `directories.removeLast()` from `while !directories.isEmpty` does. The mutant is then stopped at its time limit and ends as a timeout, which the score counts as a survivor, unless the log already shows a failed test or a crash. These mutants are kept, as there's no telling them from the rest: on SwiftProjectLint, 5 of the 36 in such bodies timed out, while a rule that skips a call whose receiver is in the loop's condition would have caught at most 3 of those 5 and dropped 10 others, 8 of which tests killed.

Removing from every body, and under `try` and `await`, took the operator from 940 mutants to 1,702 on SwiftProjectLint at `76fcfca9`, 81% more. Calls under `try` and `await` added 5, the calls of a function body that holds a loop, `guard` or `do` 242, initializers 4, closures 13, `if` and `else` branches 465, `switch` cases 30 and `defer` bodies 3; deinitializers, accessors and `catch` bodies added none there. All 1,702 build together. Of the 762 new ones, 653 were killed (86%, 12 of them by a crash), 104 survived, and 5 timed out, each again when run a second time: 3 in closures and 2 in `defer` bodies, each removing a call that another task waits for, as `batch.workerFinished()` is.

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
* **A condition that is one comparison, `==`, `!=`, `<`, `<=`, `>` or `>=`, while `RelationalOperatorReplacement` is on and gives it a constant.** `!(a % 2 == 0)` gives the same wrong result as that operator's `true` or `false` wherever the constant is wrong, and almost any test kills it elsewhere, so a test that kills the constant kills it too (see [Relational Operator Replacement](#relational-operator-replacement)). In a `while` condition, where that operator leaves out the constant that would keep the loop going, what it keeps is wrong only where the negation is too. `a == b && c` isn't one, and nor is a comparison that operator gives no constant, as `$0 > 1` in a closure that uses `$0` nowhere else, or one whose mutants a `muter:disable` comment leaves out while it doesn't reach where the condition starts, as then nothing stands for the negation. `===` and `!==` are negated, as no other operator changes them. `--mutant` still finds such a mutant that a run without that operator reported.
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

`x == true` gets a mutant here, `x == false`, and two from `RelationalOperatorReplacement`, `true` and `false`; no two of them give the same results.

### Mutating a literal
```swift
return true
```

becomes

```swift
return false
```

## Replace Boolean Value

The replace boolean value operator, `ReplaceBooleanValue`, will replace a Bool value with `true`, and in a second mutant with `false`, as PIT's `TRUE_RETURNS` and `FALSE_RETURNS` do.

The purpose of this operator is to highlight whether your tests see a value both true and false. A value such as `return items.isEmpty`, `var isReady: Bool { flag }` or `let hidden = !visible` holds no comparison, `&&` or literal, so no other operator mutates it. A test that sees the value only when it is true kills the `false` mutant and lets the `true` one survive. The pair also stands for the value's negation: a test that tells `true` from `false` tells the value from its opposite.

A value is:

* **What a body returns:** the value of a `return`, or the one expression of a body that returns it, in a function, a getter of a computed property, a `get` accessor, a subscript, or a closure whose signature writes its return type, as in `{ (item) -> Bool in item.isReady }`.
* **The initial value of a `let` or `var` of one name,** in a function, or as a stored property, a `static` or a global. A stored property's, a `static`'s and a global's value are switched in the value itself, as other operators' mutants there are (see [Mutants outside function bodies](../README.md#mutants-outside-function-bodies)).

A syntax tree has no types, so a value counts when the code shows it is a Bool:

* **Its type is written as `Bool`,** or `Swift.Bool`: the return type of what returns it, or the binding's annotation, as in `let ok: Bool = check()`. `Bool?`, `some`, a typealias and a generic parameter are other types to the tree, so `func f() -> Bool? { flag }` gets no mutant, and nor does `let empty = items.isEmpty`.
* **The last thing it works out is a comparison** (`==`, `!=`, `<`, `<=`, `>`, `>=`, `===` or `!==`), **`&&`, `||` or a prefix `!`,** inside any parentheses, `try`, `try!` and `await`, when no type is written, or the type written is `Bool` or an optional `Bool` (`Bool?`, `Bool!`, `Optional<Bool>`). A value under any other written type, as in `func f() -> SQLExpression { a == b }`, `-> Int` or `var x: Binding<Bool> { !$y }`, gets no mutant, as its operator is an overload that gives that type. The tree isn't folded, so that takes the operators' precedence: `a + 1 < b` counts, and `a < b ? c : d` and `flag ?? (a < b)` don't. An operator the standard library doesn't declare, whose precedence isn't known, doesn't count, though a type written as `Bool` still does.

Some values are left alone:

* **A comparison, while `RelationalOperatorReplacement` is on and gives it a constant,** as in `return a < b` or `let same = a == b`. That operator replaces the comparison with `true` and `false` when it is `==` or `!=`, and with one of them when it orders, beside a swap and [`RelationalBoundary`](#relational-boundary)'s mutant that are wrong wherever the other constant would be (see [Relational Operator Replacement](#relational-operator-replacement)). `&&`, `||`, `!`, `===` and `!==` stay this operator's, and so does a comparison under any of them, as in `!(a < b)`, and one whose mutants a `muter:disable` comment leaves out while it doesn't reach where the value starts or ends. `--mutant` still finds such a mutant that a run without that operator reported.
* **A literal,** as in `return true`, which `FlipBooleanLiteral` flips.
* **An `if` or `switch` expression, and its branches:** neither the whole expression nor a branch's value is replaced, though a `return` inside an `if` or `switch` statement still is.
* **What a closure that doesn't write its return type returns,** as in `items.filter { $0.isReady }`. Such closures are mostly predicates passed to `filter`, `sorted` or `contains`, and each would add a pair. A `return` in one is the closure's, even inside a function that returns `Bool`.
* **`if let`, `guard let` and `case let`, a tuple's names, `_`, an assignment** such as `isReady = a < b`, and a default argument.
* **A value under `try?`,** which makes an optional: `true` in its place would no longer be one.
* **What returns nothing:** an initializer's `return nil`, a setter and an observer such as `didSet`.

The `true` mutant is placed where the value starts, and the `false` one where it ends, so each has a place, and a switch, of its own, and `--mutant` can name either with the operator: under `--mutant`, `RelationalOperatorReplacement`'s constants of a comparison value start and end at the same places, so a place alone may name two and be refused with both listed.

A few of these mutants don't compile, and are [left out as build errors](../README.md#mutants-that-dont-compile), at the cost of a rebuild: a comparison with no type written that a module declares to give something other than a Bool, as a query builder's `==` that gives a filter does in `static let isAdult = Column("age") >= 18`. Neither `true` nor `false` is such a value. A stored property's, a `static`'s or a global's value is switched as an `if` expression, so the build error is blamed on its whole switch, which also leaves out the other operators' mutants of that value.

Some make the compiler warn, which is a build error only [with warnings as errors](../README.md#before-a-long-run): a local whose only reader was the replaced value, as `count` in `let count = items.count; return count > 0`, which is now never used, as Swift warns of a `let` or `var` that is initialized and never read; and a local `let` that is now `true` or `false`, read later by an `if`, `guard`, `while` or `?:`, whose other branch the compiler says will never be executed.

A mutant that compiles can loop forever, as a `false` that a loop waits on to be `true` does, and is then stopped at its time limit and ends as a timeout. One that sends recursion down the branch that doesn't stop crashes, which counts as killing it.

### Mutating a value
```swift
var isIdle: Bool {
    queue.isEmpty
}
```

becomes

```swift
var isIdle: Bool {
    true
}
```

and

```swift
var isIdle: Bool {
    false
}
```

## What each operator catches and costs

SwiftMutator has no tiers of operators: all nine run by default, and `--operators`, `--skip-operators` and the `operators` and `skipOperators` keys narrow a run. These numbers, from each run's `results.jsonl`, are why. Killed and survived are shares of the mutants tested, so they leave out build errors.

Operator | SwiftProjectLint: mutants | Killed | Survived | Timed out | Build errors | SwiftCloneDetector: mutants | Killed | Survived | Timed out | Build errors
---------|-----|-----|-----|---|---|-----|-----|-----|---|---
`NegateConditional` | 122 | 89% | 9% | 2 | 0 | 90 | 92% | 8% | 0 | 0
`RelationalOperatorReplacement`, before its sufficient set | 185 | 86% | 13% | 1 | 0 | 115 | 77% | 22% | 1 | 0
`ReplaceBooleanValue` | 1180 | 80% | 19% | 4 | 0 | 54 | 74% | 26% | 0 | 0
`RemoveSideEffects` | 94 | 81% | 18% | 1 | 0 | 45 | 89% | 11% | 0 | 0
`FlipBooleanLiteral` | 1335 | 79% | 20% | 6 | 0 | 25 | 72% | 28% | 0 | 0
`SwapTernary` | 19 | 79% | 21% | 0 | 0 | 23 | 52% | 48% | 0 | 0
`ChangeArithmeticOperator` | 217 | 61% | 35% | 8 | 1 | 53 | 68% | 30% | 1 | 0
`ChangeLogicalConnector` | 51 | 61% | 39% | 0 | 0 | 27 | 63% | 37% | 0 | 0
`RelationalBoundary` | 29 | 48% | 52% | 0 | 0 | 88 | 35% | 65% | 0 | 0

Measured on 5 November 2026, on SwiftProjectLint `76fcfca9` at 4 workers and SwiftCloneDetector `e03e865` with all eight. On SwiftProjectLint, the two new operators ran in full, and the six older ones as a random sample of 500 of their 5,534 mutants, so their counts there are small. `FlipBooleanLiteral`'s run there came before the last changes to `ChangeArithmeticOperator`, which don't touch its mutants: four plans since find the same ones, but for up to 2 fewer or 1 more as coverage runs reach a little more or less of the project. `ReplaceBooleanValue` ran alone, in full, on 8 November, on the same commits of both projects.

`RelationalOperatorReplacement`'s row was measured before it gave Kaminski, Ammann and Offutt's sufficient set, when it gave each comparison one mutant, `==` swapped for `!=` and `<` reversed to `>`. It now gives each two, a swap and a constant or two constants, so its counts and rates there no longer hold, and nor does `NegateConditional`'s, which now leaves every comparison to it, not only `==` and `!=`. `ReplaceBooleanValue`'s row, from a run of it alone, holds the comparisons it now leaves to `RelationalOperatorReplacement` in a run of both.

* **Nearly every mutant builds.** 1 of these 3,752 mutants was a build error. On its own five projects, swift-mutation-testing counts 12.1% of its arithmetic mutants and 11.5% of its boolean-literal ones as unviable, and it keeps both out of its default tier. Its rules and its projects differ, so the figures aren't like for like.
* **Kill rates don't sort the operators into tiers.** `SwapTernary` is 79% on one project and 52% on the other, a wider gap than between most operators. `ChangeLogicalConnector` and `SwapTernary` are in swift-mutation-testing's default tier, yet here they score below `RelationalOperatorReplacement` and `RemoveSideEffects`, which aren't. A low rate can also be an operator doing its job: a `RelationalBoundary` mutant survives unless a test checks the edge value.
* **Survivors can cluster.** 55 of `ChangeArithmeticOperator`'s 76 survivors on SwiftProjectLint track a depth: a recursive call's `depth + 1`, or a counter such as `typeNestingDepth -= 1`.
* **The cost differs more than the catch.** `FlipBooleanLiteral` gave 1,335 mutants on one project and 25 on the other. The two new operators together add 28% to SwiftProjectLint's mutants and 20% to SwiftCloneDetector's. On SwiftProjectLint a mutant took 8.6 s on average under the six older operators, 9.4 s under `FlipBooleanLiteral` and 14.1 s under `ChangeArithmeticOperator`. `ReplaceBooleanValue` gave 1,180 mutants, two for each of 590 values, on SwiftProjectLint, at 7.0 s each, so 46 minutes at 4 workers, and 54 on SwiftCloneDetector.
* **Arithmetic times out most.** On SwiftProjectLint 3.7% of its mutants timed out, against 0.8% for the six older operators and 0.4% for `FlipBooleanLiteral`. All 8 were `+=` or `-=`, as in `index += 1`, and running them again took 14 of that 32-minute run's minutes.

A project that finds an operator too costly can turn it off, as with `skipOperators: [FlipBooleanLiteral]`. Two projects are few, and numbers from more could change this.
