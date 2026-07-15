# Trivially-Identical-Sample: Measuring the Performance Improvements from SE-0494

The [SE-0494](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0494-add-is-identical-methods.md) Swift Evolution Proposal added a new set of “performance hook” APIs to the Swift Standard Library. The `isTriviallyIdentical(to:)` methods are alternatives to testing collections for value equality.

Suppose we have a Swift `Array` of `n` data model elements. What is the *worst* case performance of testing this for value equality against another `Array`? It’s `O(n)`: we have to visit *every* element in our `Array`. There do exist “fast path” early returns: if two `Array` values have a different number of elements they *cannot* be equal and we can return `false` in constant time.[^1] There also exists an early return in the other direction: if two `Array` values are backed by the same backing storage buffer we can return `true` in constant time.[^2]

Swift Standard Library collections are copy-on-write data structures. These types adopt the contract of value semantics on their public interface, but adopt *reference* semantics in their private implementation to improve performance.[^3] Historically, Swift Standard Library did not really “expose” these reference semantics as a safe public API. The `isTriviallyIdentical(to:)` methods expose a “slice” of reference semantics: if two collections share the same backing storage buffer these types *must* be equal by-value.

The evolution proposal presents a theoretical and abstract argument for how these APIs could improve performance. Let’s work together through an example SwiftUI project to see how and where these could be used. We will measure our performance in Instruments and compare the performance of `isTriviallyIdentical(to:)` against conventional value equality.

> [!NOTE]
> As of this writing the `isTriviallyIdentical(to:)` APIs have not yet shipped to the production Swift Toolchain. We will be working together from `Xcode_27_beta_3` and `swiftlang-6.4.0.25.4` to preview these changes before they are officially released.

## Food Truck

Our experiment will build from the [`sample-food-truck`](https://github.com/apple/sample-food-truck) tutorial repo from Apple. The project gives us a good place to measure the performance of building SwiftUI view components against many data models.

The `sample-food-truck` repo supports building for multiple platforms including iOS and watchOS. We will focus on macOS for our analysis. Here is what the app looks like built for macOS:

<picture>
 <source media="(prefers-color-scheme: dark)" srcset="2026-07-14-2.png">
 <source media="(prefers-color-scheme: light)" srcset="2026-07-14-1.png">
 <img src="2026-07-14-1.png">
</picture>

We will spend most of our time investigating the `OrdersTable`. Here is what that component looks like:

<picture>
 <source media="(prefers-color-scheme: dark)" srcset="2026-07-14-4.png">
 <source media="(prefers-color-scheme: light)" srcset="2026-07-14-3.png">
 <img src="2026-07-14-3.png">
</picture>

The `OrdersTable` is a SwiftUI component that reads and displays data from a `FoodTruckModel` object instance. The `FoodTruckModel` object instance manages an `Array` of `Order` value types. Our sample app from Apple launches with 24 `Order` instances generated from a `OrderGenerator`. We will increase this by three orders of magnitude and measure performance as we test `isTriviallyIdentical(to:)` against value equality.

Feel free to look around this code and investigate how things are currently architected before moving forward. We will be hacking on the sample project from Apple to collect our measurements. You can choose to follow along by hacking on the Apple repo, or you can clone the `Trivially-Identical-Sample` fork to see the complete project with our changes already implemented.

We start with a hack on `FoodTruckModel`. The `FoodTruckModel` comes with some code to simulate new orders coming in after the app is launched. This can make our measurements a little more noisy than necessary. Let’s disable this functionality before moving forward:

```diff
         monthlyOrderSummaries = Dictionary(uniqueKeysWithValues: City.all.map { city in
             (key: city.id, orderGenerator.historicalMonthlyOrders(since: .now, cityID: city.id))
         })
-        Task(priority: .background) {
-            var generator = OrderGenerator.SeededRandomGenerator(seed: 5)
-            for _ in 0..<20 {
-                try? await Task.sleep(nanoseconds: .secondsToNanoseconds(.random(in: 3 ... 8, using: &generator)))
-                Task { @MainActor in
-                    withAnimation(.spring(response: 0.4, dampingFraction: 1)) {
-                        self.orders.append(orderGenerator.generateOrder(number: orders.count + 1, date: .now, generator: &generator))
-                    }
-                }
-            }
-        }
```

The `FoodTruckModel` uses the `OrderGenerator` type to build its `Array` of `Order` elements. Let’s make these two changes in `OrderGenerator` to measure at a larger scale:

```diff
         let startingDate = Date.now
         var generator = SeededRandomGenerator(seed: 1)
         var previousOrderTime = startingDate.addingTimeInterval(-60 * 4)
-        let totalOrders = 24
+        let totalOrders = 24_000
         return (0 ..< totalOrders).map { index in
             previousOrderTime -= .random(in: 60 ..< 180, using: &generator)
```
```diff
         let totalSales = sales.map(\.value).reduce(0, +)
         return Order(
-            id: String(localized: "Order") + String(localized: ("#\(12)\(number, specifier: "%02d")")),
+            id: "Order#\(number)",
             status: .placed,
             donuts: Array(donuts),
             sales: sales,
```

Try building and running the app now to see 24,000 orders displayed in `OrdersTable`.

## Memoization

Our `OrdersTable` currently computes the filtered and sorted `orders` *every* time the view `body` is computed:

```swift
var orders: [Order] {
    model.orders.filter { order in
        order.matches(searchText: searchText) || order.donuts.contains(where: { $0.matches(searchText: searchText) })
    }
    .sorted(using: sortOrder)
}

var body: some View {
    Table(selection: $selection, sortOrder: $sortOrder) {
        ...
    } rows: {
        Section {
            ForEach(orders) { order in
                TableRow(order)
            }
        }
    }
}
```

This is *expensive*: we are currently doing no work to memoize or cache these values. In [Swift-CowBox-Sample](https://github.com/Swift-CowBox/Swift-CowBox-Sample) we saw a different approach. We will memoize our computed `orders` property. If the *input* to this derived state has not changed we can return the previous *output* in constant time.

Here is what a memoized property wrapper looks like for `OrdersTable`:

```swift
@propertyWrapper struct SortedOrders: DynamicProperty {
  @State var sortOrder = [KeyPathComparator(\Order.creationDate, order: .forward)]
  
  @State private var storage = Storage()
  
  private var orders: [Order]
  private var searchText: String
  
  init(
    orders: [Order],
    searchText: String
  ) {
    self.orders = orders
    self.searchText = searchText
  }
  
  var wrappedValue: [Order] {
    self.storage.wrappedValue
  }
  
  func update() {
    let signposter = OSSignposter()
    let state = signposter.beginInterval("SortedOrders.update")
    defer {
      signposter.endInterval("SortedOrders.update", state)
    }
    self.storage.update(
      orders: self.orders,
      searchText: self.searchText,
      sortOrder: self.sortOrder
    )
  }
}

extension SortedOrders {
  final class Storage {
    private var output: [Order]? = nil
    private var orders: [Order] = []
    private var searchText: String = ""
    private var sortOrder: [KeyPathComparator<Order>] = []
    
    var wrappedValue: [Order] {
      guard
        let output = self.output
      else {
        fatalError("missing output")
      }
      return output
    }
    
    func update(
      orders: [Order],
      searchText: String,
      sortOrder: [KeyPathComparator<Order>]
    ) {
      if self.shouldUpdateOutput(
        orders: orders,
        searchText: searchText,
        sortOrder: sortOrder
      ) {
        self.orders = orders
        self.searchText = searchText
        self.sortOrder = sortOrder
        self.updateOutput()
      }
    }
    
    private func shouldUpdateOutput(
      orders: [Order],
      searchText: String,
      sortOrder: [KeyPathComparator<Order>]
    ) -> Bool {
      if self.output != nil,
         self.orders == orders,
         self.searchText == searchText,
         self.sortOrder == sortOrder {
        return false
      } else {
        return true
      }
    }
    
    private func updateOutput() {
      if self.searchText.isEmpty {
        self.output = self.orders.sorted(using: self.sortOrder)
      } else {
        self.output = self.orders.filter { order in
          order.matches(searchText: self.searchText) || order.donuts.contains(where: { $0.matches(searchText: self.searchText) })
        }.sorted(using: self.sortOrder)
      }
    }
  }
}
```

It’s almost 100 lines of code, but it’s not very complicated work. Let’s quickly look through to see what is happening:

* We construct `SortedOrders` with an array of `Order` models and a `String` we use to search and filter these models.
* Our `SortedOrders` dynamic property wrapper returns an `Array` of filtered and sorted `Order` models from `SortedOrders.Storage` as a `wrappedValue`.
* Our `SortedOrders` wrapper exposes a `State` variable that controls the sort order of our `wrappedValue`. Our default value with be `forward` sorting on `creationDate`.
* Our `SortedOrders` wrapper implements `update` and forwards its current values through to `SortedOrders.Storage`. We also add an `OSSignposter` here for our performance measurements.

Let’s look closer at `SortedOrders.Storage`:

* Our `update(orders:searchText:sortOrder:)` method passes these values to a `shouldUpdateOutput(orders:searchText:sortOrder:)` method. This returns `true` to indicate we should compute a new `output` value.
* Our `wrappedValue` returns our computed `output`. Because `DynamicProperty` will call `update` *before* our view `body` is computed our `output` should have already been computed. We will crash with `fatalError` for now to indicate this is being used outside of a traditional SwiftUI lifecycle.

Let’s take a closer look at the `shouldUpdateOutput(orders:searchText:sortOrder:)` method. We start by testing if our current `output` is `nil`. If we have never computed an `output` then we return `true` to indicate we must compute a new one. If we do have a computed `output`, we test the `orders` value called from `update` against the *previous* `orders` value at the time we computed our last `output` value. If these values are *not* equal by value equality we return true to indicate we must compute a new `output`. Remember: this is a `O(n)` operation that potentially visits *every* data model element in our `Array`.

Let’s refactor our `OrdersTable` view component to use this new memoized dynamic property.

```diff
 struct OrdersTable: View {
     @ObservedObject var model: FoodTruckModel
-    @State private var sortOrder = [KeyPathComparator(\Order.status, order: .reverse)]
     @Binding var selection: Set<Order.ID>
     @Binding var completedOrder: Order?
     @Binding var searchText: String
     
-    var orders: [Order] {
-        model.orders.filter { order in
-            order.matches(searchText: searchText) || order.donuts.contains(where: { $0.matches(searchText: searchText) })
-        }
-        .sorted(using: sortOrder)
+    @SortedOrders private var orders: [Order]
+    
+    init(model: FoodTruckModel, selection: Binding<Set<Order.ID>>, completedOrder: Binding<Order?>, searchText: Binding<String>) {
+        self.model = model
+        self._selection = selection
+        self._completedOrder = completedOrder
+        self._searchText = searchText
+        self._orders = SortedOrders(orders: model.orders, searchText: searchText.wrappedValue)
     }
     
     var body: some View {
-        Table(selection: $selection, sortOrder: $sortOrder) {
+        Table(selection: $selection, sortOrder: _orders.$sortOrder) {
             TableColumn("Order", value: \.id) { order in
                 OrderRow(order: order)
                     .frame(maxWidth: .infinity, alignment: .leading)
```

## Measurements

The `Swift-CowBox-Sample` repo contains a detailed performance analysis comparing the performance of memoization against our original implementation: it’s a big performance win. What we care about here now is optimizing the memoization operation *itself*.

Let’s build and run so we can see how these measurements look. We launch Instruments and select the `os_signposts` instrument. Let’s try the same experiment from `Swift-CowBox-Sample`:

* Launch App.
* Navigate to `OrdersTable`.
* Select the top `Order`.
* Mark the first `Order` as completed.
* Select the second `Order`.
* Mark the second `Order` as completed.
* Continue selecting the top ten `Order` instances and marking each as completed (one at a time).

Here are our measurements from the `os_signposts` instrument:

| SortedOrders.update | Avg Duration | Std Dev Duration | Count | Total Duration
| --- | --- | --- | --- | --- |
| Control | 11.35 ms | 15.82 ms | 61 | 692.49 ms

Our experiment ran for 692.49 ms on `SortedOrders.update`. Keep in mind that SwiftUI runs `SortedOrders.update` on `MainActor` before *every* `view` body property is computed on `OrdersTable`. Our incentive as app developers is to try and keep this work as fast as possible.

Let’s now make one small change: we update our `SortedOrders.Storage` to use our new `isTriviallyIdentical(to:)` method instead of value equality to determine if we should compute a new `output` value:

```diff
extension SortedOrders {
  final class Storage {
    ...
    
    private func shouldUpdateOutput(
      orders: [Order],
      searchText: String,
      sortOrder: [KeyPathComparator<Order>]
    ) -> Bool {
      if self.output != nil,
-         self.orders == orders,
+         self.orders.isTriviallyIdentical(to: orders),
         self.searchText == searchText,
         self.sortOrder == sortOrder {
        return false
      } else {
        return true
      }
    }
    
    ...
  }
}
```

Testing these two `Array` collections for value equality was an `O(n)` operation. Our new `isTriviallyIdentical(to:)` is guaranteed to return in constant time: `O(1)`.

Let’s see what happens when we try our experiment again. Here are our results from the `os_signposts` instrument:

| SortedOrders.update | Avg Duration | Std Dev Duration | Count | Total Duration
| --- | --- | --- | --- | --- |
| Control | 11.35 ms | 15.82 ms | 61 | 692.49 ms
| Test | 9.86 ms | 13.78 ms | 61 | 601.41 ms

Our control group built from value equality spent 692.49 ms on `MainActor` performing work in `SortedOrders.update`. Our test group built from *reference* equality spent 601.41 ms from the same user events. This is about a 13 percent improvement after changing one line of code.

These measurements can be found in the `Instruments` directory of the `Trivially-Identical-Sample` fork. These were recorded from a MacBook Pro M2 Max. Your results could be faster or slower depending on your machine. What matters more for now is the *relative* difference between your control group and your test group. Not the *absolute* values.

## Analysis

So where did this performance improvement come from? Let’s look a little deeper at what happens when our user selects an `Order` data model and marks it as completed. Our `FoodTruckModel` stores an `Array` of `Order` models. The Swift `Array` is an immutable data structure that adopts value semantics. Because our `Order` models *also* adopt value semantics, mutating one `Order` model mutates our `Array`. This triggers a copy-on-write operation: our `Array` will now create a new buffer reference. This means that `isTriviallyIdentical(to:)` will now return `false` in constant time.

What about the performance of value equality? If our `Array` values matched to the *same* buffer storage reference we could return `true` in constant time. If our `Array` values contained a different number of elements we could return `false` in constant time. Because mutating one `Order` model element means we now have the same number of elements *and* a different buffer storage reference, we must iterate through all `n` elements in linear time.

It’s important to call out one very important decision we took when building our `SortedOrders` dynamic property: the default value of our `sortOrder` sorts `forward` over `creationDate`. This implies that when we mutate the first `Order` in our `Table` we are actually mutating the *last* element in our `Array`.

You can experiment with this yourself to see how this impacts performance. Try sorting `reverse` over `creationDate` and run the same measurements again. You should see performance look much closer between your test group and control group. Your `SortedOrders.update` method still performs a linear time algorithm to compare all `Order` elements. But since the `Order` element that has been changed is now near the *front* of the `Array` this will return much faster.

Is this “cheating”? Are we “cooking the books”. Well… yes and no. It’s a totally legit critique at this point to argue that our experiment is not something general purpose that scales to a wide variety of applications and products. But… that’s also sort of the whole point. The `isTriviallyIdentical(to:)` methods are *niche* operations. These are “hipster” APIs: something “underground” that might not really ever cross over to a mainstream audience.

At the end of the day you are the one who knows the most about the performance of your applications and products. Measure the time spent performing checks for value equality. Make the change to `isTriviallyIdentical(to:)` and measure the time spent performing checks for reference equality. Measure these changes using the real world user experiences in your products.

Be sure to also consider any “downstream” side effects from your comparisons: what business logic happens after two values are not equal or not identical? You might end up with a situation where your value equality checks actually *save* you performance down the road. That’s ok. You should continue using value equality checks when it makes sense to do so.

Our `FoodTruckModel` class currently saves its `orders` as a *stored* instance property. Suppose for some reason `FoodTruckModel` was refactored and now `orders` is a *computed* property that returns a new `Array` of data models *every time* it is called. Every time we request `orders` we get a *new* `Array` with a *new* identity even when the `Order` data model elements *themselves* are exactly the same. When `SortedOrders` then calls `isTriviallyIdentical(to:)` we will return `false`. But these `Array` values *are* equal by value. What happens to performance? We return from `isTriviallyIdentical(to:)` in constant time… but we then sort our `Array` in `O(n log n)` time. Suppose we replace `isTriviallyIdentical(to:)` with a traditional `==` check for value equality: this is an `O(n)` operation that returns `true` and we *do not* perform an `O(n log n)` sort operation. We would expect the aggregate sum of time spent in `SortedOrders.update` to actually get *slower* from `isTriviallyIdentical(to:)` because of all the unnecessary sorting.

The purpose of the `isTriviallyIdentical(to:)` APIs is to start offering a choice to developers: measure these in your own products and use your best judgement for when it does and does not make sense to make the switch.

## Copyright

Copyright 2026 North Bronson Software

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

[^1]: <https://github.com/swiftlang/swift/blob/swift-6.3.3-RELEASE/stdlib/public/core/Array.swift#L1988-L1991>
[^2]: <https://github.com/swiftlang/swift/blob/swift-6.3.3-RELEASE/stdlib/public/core/Array.swift#L1993-L1996>
[^3]: <https://www.youtube.com/watch?v=m9JZmP9E12M>
