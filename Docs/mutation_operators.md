# Mutation Operators
SwiftMutator uses **mutation operators** to generate mutants in your source code. This is the list of currently available mutation operators.

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
* A line does not contain a call to `print`, `exit`, `fatalError`, `abort`, or any function listed in `muter.conf.yml` under the `excludeCalls` key.

The purpose of this operator is to highlight how your tests respond to the absence of expected side effects.

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
