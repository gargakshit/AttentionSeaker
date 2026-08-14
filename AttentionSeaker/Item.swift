//
//  Item.swift
//  AttentionSeaker
//
//  Created by Akshit Garg on 14/08/26.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
