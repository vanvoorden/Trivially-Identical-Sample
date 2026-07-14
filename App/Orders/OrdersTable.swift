/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
The orders table.
*/

import SwiftUI
import FoodTruckKit
import os

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
         self.orders.isTriviallyIdentical(to: orders),
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

struct OrdersTable: View {
    @ObservedObject var model: FoodTruckModel
    @Binding var selection: Set<Order.ID>
    @Binding var completedOrder: Order?
    @Binding var searchText: String
    
    @SortedOrders private var orders: [Order]
  
    init(model: FoodTruckModel, selection: Binding<Set<Order.ID>>, completedOrder: Binding<Order?>, searchText: Binding<String>) {
        self.model = model
        self._selection = selection
        self._completedOrder = completedOrder
        self._searchText = searchText
        self._orders = SortedOrders(orders: model.orders, searchText: searchText.wrappedValue)
     }
    
    var body: some View {
        Table(selection: $selection, sortOrder: _orders.$sortOrder) {
            TableColumn("Order", value: \.id) { order in
                OrderRow(order: order)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)
            }
            
            TableColumn("Donuts", value: \.totalSales) { order in
                Text(order.totalSales.formatted())
                    .monospacedDigit()
                    #if os(macOS)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .foregroundStyle(.secondary)
                    #endif
            }
            
            TableColumn("Status", value: \.status) { order in
                order.status.label
                    #if os(macOS)
                    .foregroundStyle(.secondary)
                    #endif
            }
            
            TableColumn("Date", value: \.creationDate) { order in
                Text(order.formattedDate)
                    #if os(macOS)
                    .foregroundStyle(.secondary)
                    #endif
            }
            
            TableColumn("Details") { order in
                Menu {
                    NavigationLink(value: order.id) {
                        Label("View Details", systemImage: "list.bullet.below.rectangle")
                    }
                    
                    if !order.isComplete {
                        Section {
                            Button {
                                model.markOrderAsCompleted(id: order.id)
                                completedOrder = order
                            } label: {
                                Label("Complete Order", systemImage: "checkmark")
                            }
                        }
                    }
                } label: {
                    Label("Details", systemImage: "ellipsis.circle")
                        .labelStyle(.iconOnly)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundColor(.secondary)
            }
            .width(60)
        } rows: {
            Section {
                ForEach(orders) { order in
                    TableRow(order)
                }
            }
        }
    }
}

struct OrdersTable_Previews: PreviewProvider {
    
    @State private var sortOrder = [KeyPathComparator(\Order.status, order: .reverse)]
    
    struct Preview: View {
        @StateObject private var model = FoodTruckModel.preview
        
        var body: some View {
            OrdersTable(
                model: FoodTruckModel.preview,
                selection: .constant([]),
                completedOrder: .constant(nil),
                searchText: .constant("")
            )
        }
    }
    
    static var previews: some View {
        Preview()
    }
}

//struct OrdersTable_Previews: PreviewProvider {
//    static var previews: some View {
//        OrdersTable()
//    }
//}
