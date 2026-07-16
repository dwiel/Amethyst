//
//  LogManager.swift
//  Amethyst
//
//  Created by Ian Ynda-Hummel on 5/19/16.
//  Copyright © 2016 Ian Ynda-Hummel. All rights reserved.
//

import Foundation
import SwiftyBeaver

let log = SwiftyBeaver.self

private let persistentLogDirectoryName = "Amethyst"
private let persistentLogFileName = "Amethyst.log"

@discardableResult
func configurePersistentLogging() -> URL? {
    guard let libraryURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else {
        return nil
    }

    let logFileURL = libraryURL
        .appendingPathComponent("Logs", isDirectory: true)
        .appendingPathComponent(persistentLogDirectoryName, isDirectory: true)
        .appendingPathComponent(persistentLogFileName, isDirectory: false)
    let destination = FileDestination(logFileURL: logFileURL)
    destination.format = "$Dyyyy-MM-dd HH:mm:ss.SSS$d $L $N.$F:$l - $M"
    destination.minLevel = .debug
    destination.logFileMaxSize = 5 * 1024 * 1024
    destination.logFileAmount = 5
    destination.syncAfterEachWrite = true
    log.addDestination(destination)

    return logFileURL
}
