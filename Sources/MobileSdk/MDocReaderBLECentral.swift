//
//  MdocReaderBLECentral.swift
//  AqReader
//
//  Created by Warren Gallagher on 2024-12-09.
//

import Algorithms
import CoreBluetooth
import Foundation
import os
import SpruceIDMobileSdkRs

/// Characteristic errors.
//enum CharacteristicsError: Error {
//    case missingMandatoryCharacteristic(name: String)
//    case missingMandatoryProperty(name: String, characteristicName: String)
//}

/// Data errors.
//enum DataError: Error {
//    case noData(characteristic: CBUUID)
//    case invalidStateLength
//    case unknownState(byte: UInt8)
//    case unknownCharacteristic(uuid: CBUUID)
//    case unknownDataTransferPrefix(byte: UInt8)
//}

/// The MDoc holder as a BLE central.
class MDocReaderBLECentral: NSObject {
    enum MachineState {
        case initial, hardwareOn, fatalError, complete, halted, servicePublished
        case awaitPeripheralDiscovery, peripheralDiscovered, checkPeripheral
        case l2capRead, l2capAwaitChannelPublished, l2capChannelPublished
        case l2capStreamOpen, l2capSendingRequest, l2capAwaitingResponse
        case stateSubscribed, awaitRequestStart, sendingRequest, awaitResponse
    }

    var centralManager: CBCentralManager!
    var serviceUuid: CBUUID
    var callback: MDocReaderBLECentralDelegate
    var peripheral: CBPeripheral?
    var writeCharacteristic: CBCharacteristic?
    var readCharacteristic: CBCharacteristic?
    var stateCharacteristic: CBCharacteristic?
    var identCharacteristic: CBCharacteristic?
    var l2capCharacteristic: CBCharacteristic?
    var requestData: Data
    var requestSent = false
    var maximumCharacteristicSize: Int?
    var writingQueueTotalChunks: Int?
    var writingQueueChunkIndex: Int?
    var writingQueue: IndexingIterator<ChunksOfCountCollection<Data>>?

    var incomingMessageBuffer = Data()
    var outgoingMessageBuffer = Data()
    var incomingMessageIndex = 0

    private var channelPSM: UInt16?
    private var activeStream: MDocReaderBLECentralConnection?
    
    /// If this is `false`, we decline to connect to L2CAP even if it is offered.
    var useL2CAP: Bool

    var machineState = MachineState.initial
    var machinePendingState = MachineState.initial {
        didSet {
            updateState()
        }
    }

    init(callback: MDocReaderBLECentralDelegate, request: Data, serviceUuid: CBUUID, useL2CAP: Bool) {
        self.serviceUuid = serviceUuid
        self.callback = callback
        self.useL2CAP = useL2CAP
        self.requestData = request
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }

    /// Update the state machine.
    private func updateState() {
        var update = true

        while update {
            if machineState != machinePendingState {
                print("「\(machineState) → \(machinePendingState)」")
            } else {
                print("「\(machineState)」")
            }

            update = false

            switch machineState {
            /// Core.
            case .initial: // Object just initialized, hardware not ready.
                if machinePendingState == .hardwareOn {
                    machineState = machinePendingState
                    update = true
                }

            case .hardwareOn: // Hardware is ready.
                centralManager.scanForPeripherals(withServices: [serviceUuid])
                machineState = machinePendingState
                machinePendingState = .awaitPeripheralDiscovery

            case .awaitPeripheralDiscovery:
                if machinePendingState == .peripheralDiscovered {
                    machineState = machinePendingState
                }

            case .peripheralDiscovered:
                if machinePendingState == .checkPeripheral {
                    machineState = machinePendingState
                    //machinePendingState = .stateSubscribed
                    centralManager?.stopScan()
                    callback.updateForCentralClientMode(message: .connected)
                }

            case .servicePublished: // Characteristics set up, we're publishing our service.
                if machinePendingState == .l2capRead {
                    machineState = machinePendingState
                    update = true
                } else if machinePendingState == .stateSubscribed {
                    machineState = machinePendingState
                    update = true
                }

            case .fatalError: // Something went wrong.
                machineState = .halted
                machinePendingState = .halted
            case .complete: // Transfer complete.
                disconnect()

            case .halted: // Transfer incomplete, but we gave up.
                break

            /// L2CAP flow.
            case .l2capRead: // We have a read on our L2CAP characteristic, start L2CAP flow.
                machineState = .l2capAwaitChannelPublished

                // Setting the encryption flag here appears to break at least some Android devices; if `withEncryption`
                // is set, when the Android device calls `.connect()` on the socket it throws a "resource not
                // available" exception.  The data is already encrypted, so I'm setting it to false, and making Android
                // recover from the exception and fall back to the old flow if necessary as well.  Support code for
                // failover is in the next two states, below.

                //centralManager.publishL2CAPChannel(withEncryption: false)
                update = true

            case .l2capAwaitChannelPublished:
                if machinePendingState == .l2capChannelPublished {
                    machineState = machinePendingState
                } else if machinePendingState == .stateSubscribed {

                    // Failover case for Android; we could get this here, or in the published state.  Android devices
                    // may be unable to connect() on an L2CAP socket (see the comment in .l2capRead, above), and if
                    // they do they "switch tracks" to the old flow.  We need to notice that's happened and support
                    // it here.

                    print("Failover to non-L2CAP flow.")

                    if let psm = channelPSM {
                        //centralManager.unpublishL2CAPChannel(psm)
                    }
                    machineState = machinePendingState
                    update = true
                }

            case .l2capChannelPublished:
                if machinePendingState == .l2capStreamOpen {
                    machineState = machinePendingState
                    update = true
                } else if machinePendingState == .stateSubscribed {

                    // See the comments in .l2capRead and .l2capAwaitChannelPublished, above.

                    print("Failover to non-L2CAP flow.")

                    if let psm = channelPSM {
                        //centralManager.unpublishL2CAPChannel(psm)
                    }
                    machineState = machinePendingState
                    update = true
                }

            case .l2capStreamOpen: // An L2CAP stream is opened.
                if !requestSent {
                    // We occasionally seem to get a transient condition where the stream gets opened
                    // more than once; locally, I've seen the stream open 10 times in a row, and with
                    // the non-framed transport for data, that means we send the request 10 times, the
                    // far side reads that as a single request, and errors out.  The requestSent bool
                    // is to keep this from happening.
                    activeStream?.send(data: requestData)
                    requestSent = true
                }
                machineState = .l2capSendingRequest
                machinePendingState = .l2capSendingRequest
                update = true

            case .l2capSendingRequest: // The request is being sent over the L2CAP stream.
                print("l2capSendingRequest...  machinePendingState = \(machinePendingState)")
                if machinePendingState == .l2capAwaitingResponse {
                    machineState = machinePendingState
                    update = true
                } else if machinePendingState == .complete {
                    machineState = machinePendingState
                    callback.callback(message: MDocReaderBLECallback.message(incomingMessageBuffer))
                    update = true
                }

            case .l2capAwaitingResponse: // The request is sent, the response is (hopefully) coming in.
                if machinePendingState == .complete {
                    machineState = machinePendingState
                    callback.callback(message: MDocReaderBLECallback.message(incomingMessageBuffer))
                    update = true
                }

            /// Original flow.
            case .stateSubscribed: // We have a subscription to our State characteristic, start original flow.
                // This will trigger wallet-sdk-swift to send 0x01 to start the exchange
                //centralManager.updateValue(bleIdent, for: identCharacteristic!, onSubscribedCentrals: nil)

                // I think the updateValue() below is out of spec; 8.3.3.1.1.5 says we wait for a write without
                // response of 0x01 to State, but that's supposed to come from the holder to indicate it's ready
                // for us to initiate.

                // This will trigger wallet-sdk-kt to send 0x01 to start the exchange
                // peripheralManager.updateValue(Data([0x01]), for: self.stateCharacteristic!,
                //                               onSubscribedCentrals: nil)

                machineState = .awaitRequestStart
                machinePendingState = .awaitRequestStart

            case .awaitRequestStart: // We've let the holder know we're ready, waiting for their ack.
                if machinePendingState == .sendingRequest {
                    writeOutgoingValue(data: requestData)
                    machineState = .sendingRequest
                }

            case .sendingRequest:
                if machinePendingState == .awaitResponse {
                    machineState = .awaitResponse
                }

            case .awaitResponse:
                if machinePendingState == .complete {
                    machineState = .complete
                    update = true
                }
            case .checkPeripheral:
                if machinePendingState == .awaitRequestStart {
                    if let peri = peripheral {
                        if useL2CAP, let l2capC = l2capCharacteristic {
                            peri.setNotifyValue(true, for: l2capC)
                            peri.readValue(for: l2capC)
                            machineState = machinePendingState
                        } else if let readC = readCharacteristic,
                                  let stateC = stateCharacteristic {
                            peri.setNotifyValue(true, for: readC)
                            peri.setNotifyValue(true, for: stateC)
                            peri.writeValue(_: Data([0x01]), for: stateC, type: .withoutResponse)
                            machineState = machinePendingState
                            machinePendingState = .sendingRequest
                        }
                    }
                }
            }
        }
    }

    func disconnectFromDevice(session: MdlPresentationSession) {
        let message: Data
        do {
            message = try session.terminateSession()
        } catch {
            print("\(error)")
            message = Data([0x02])
        }
        peripheral?.writeValue(_: message,
                               for: stateCharacteristic!,
                               type: CBCharacteristicWriteType.withoutResponse)
        disconnect()
    }

    private func disconnect() {
        if let peripheral = peripheral {
            centralManager.cancelPeripheralConnection(peripheral)
        }
    }

    func writeOutgoingValue(data: Data) {
        let chunks = data.chunks(ofCount: maximumCharacteristicSize! - 1)
        writingQueueTotalChunks = chunks.count
        writingQueue = chunks.makeIterator()
        writingQueueChunkIndex = 0
        drainWritingQueue()
    }

    private func drainWritingQueue() {
        if writingQueue != nil {
            if var chunk = writingQueue?.next() {
                var firstByte: Data.Element
                writingQueueChunkIndex! += 1
                if writingQueueChunkIndex == writingQueueTotalChunks {
                    firstByte = 0x00
                } else {
                    firstByte = 0x01
                }
                chunk.reverse()
                chunk.append(firstByte)
                chunk.reverse()
                peripheral?.writeValue(_: chunk,
                                        for: writeCharacteristic!,
                                        type: CBCharacteristicWriteType.withoutResponse)
                //centralManager?.updateValue(chunk, for: writeCharacteristic!, onSubscribedCentrals: nil)

                if firstByte == 0x00 {
                    machinePendingState = .awaitResponse
                }
            } else {
                writingQueue = nil
                machinePendingState = .awaitResponse
            }
        }
    }

    /// Verify that a characteristic matches what is required of it.
    private func getCharacteristic(list: [CBCharacteristic],
                                   uuid: CBUUID, properties: [CBCharacteristicProperties],
                                   required: Bool) throws -> CBCharacteristic? {
        let chName = MDocCharacteristicNameFromUUID(uuid)

        if let candidate = list.first(where: { $0.uuid == uuid }) {
            for prop in properties where !candidate.properties.contains(prop) {
                let propName = MDocCharacteristicPropertyName(prop)
                if required {
                    throw CharacteristicsError.missingMandatoryProperty(name: propName, characteristicName: chName)
                } else {
                    return nil
                }
            }
            return candidate
        } else {
            if required {
                throw CharacteristicsError.missingMandatoryCharacteristic(name: chName)
            } else {
                return nil
            }
        }
    }

    /// Check that the reqiured characteristics are available with the required properties.
    func processCharacteristics(peripheral: CBPeripheral, characteristics: [CBCharacteristic]) throws {
        stateCharacteristic = try getCharacteristic(list: characteristics,
                                                    uuid: holderStateCharacteristicId,
                                                    properties: [.notify, .writeWithoutResponse],
                                                    required: true)

        writeCharacteristic = try getCharacteristic(list: characteristics,
                                                    uuid: holderClient2ServerCharacteristicId,
                                                    properties: [.writeWithoutResponse],
                                                    required: true)

        readCharacteristic = try getCharacteristic(list: characteristics,
                                                   uuid: holderServer2ClientCharacteristicId,
                                                   properties: [.notify],
                                                   required: true)

//        if let readerIdent = try getCharacteristic(list: characteristics,
//                                                   uuid: readerIdentCharacteristicId,
//                                                   properties: [.read],
//                                                   required: true) {
//            peripheral.readValue(for: readerIdent)
//        }

        l2capCharacteristic = try getCharacteristic(list: characteristics,
                                                    uuid: holderL2CAPCharacteristicId,
                                                    properties: [.read],
                                                    required: false)

//       iOS controls MTU negotiation. Since MTU is just a maximum, we can use a lower value than the negotiated value.
//       18013-5 expects an upper limit of 515 MTU, so we cap at this even if iOS negotiates a higher value.
//
//       maximumWriteValueLength() returns the maximum characteristic size, which is 3 less than the MTU.
        let negotiatedMaximumCharacteristicSize = peripheral.maximumWriteValueLength(for: .withoutResponse)
        maximumCharacteristicSize = min(negotiatedMaximumCharacteristicSize - 3, 512)
    }

    /// Process incoming data from a peripheral. This handles incoming data from any and all characteristics (though not
    /// the L2CAP stream...), so we hit this call multiple times from several angles, at least in the original flow.
    func processData(peripheral: CBPeripheral, characteristic: CBCharacteristic) throws {
        if var data = characteristic.value {
            let name = MDocCharacteristicNameFromUUID(characteristic.uuid)
            print("Processing \(data.count) bytes of data for \(name) → ", terminator: "")
            switch characteristic.uuid {
            case readerClient2ServerCharacteristicId:
                print("DOING THIS")
                return
//                let firstByte = data.popFirst()
//                incomingMessageBuffer.append(data)
//                switch firstByte {
//                case .none:
//                    print("Nothing?")
//                    throw DataError.noData(characteristic: characteristic.uuid)
//                case 0x00: // end
//                    print("End")
//                    callback.callback(message: MDocReaderBLECallback.message(incomingMessageBuffer))
//                    incomingMessageBuffer = Data()
//                    incomingMessageIndex = 0
//                    machinePendingState = .complete
//                    return
//                case 0x01: // partial
//                    print("Chunk")
//                    incomingMessageIndex += 1
//                    callback.callback(message: .downloadProgress(incomingMessageIndex))
//                    // TODO: check length against MTU
//                    return
//                case let .some(byte):
//                    print("Unexpected byte \(String(format: "$%02X", byte))")
//                    throw DataError.unknownDataTransferPrefix(byte: byte)
//                }
            case holderServer2ClientCharacteristicId:
                let firstByte = data.popFirst()
                incomingMessageBuffer.append(data)
                switch firstByte {
                case .none:
                    print("Nothing?")
                    throw DataError.noData(characteristic: characteristic.uuid)
                case 0x00: // end
                    print("End")
                    callback.callback(message: MDocReaderBLECallback.message(incomingMessageBuffer))
                    incomingMessageBuffer = Data()
                    incomingMessageIndex = 0
                    machinePendingState = .complete
                    return
                case 0x01: // partial
                    print("Chunk")
                    incomingMessageIndex += 1
                    callback.callback(message: .downloadProgress(incomingMessageIndex))
                    // TODO: check length against MTU
                    return
                case let .some(byte):
                    print("Unexpected byte \(String(format: "$%02X", byte))")
                    throw DataError.unknownDataTransferPrefix(byte: byte)
                }
            case readerStateCharacteristicId:
                print("State")
                if data.count != 1 {
                    throw DataError.invalidStateLength
                }
                switch data[0] {
                case 0x01:
                    machinePendingState = .sendingRequest
                case let byte:
                    throw DataError.unknownState(byte: byte)
                }

            case readerL2CAPCharacteristicId:
                print("L2CAP")
                machinePendingState = .l2capRead
                return

            case let uuid:
                print("Unexpected UUID")
                throw DataError.unknownCharacteristic(uuid: uuid)
            }
        } else {
            throw DataError.noData(characteristic: characteristic.uuid)
        }
    }
}

extension MDocReaderBLECentral: CBCentralManagerDelegate {
    /// Handle a state change in the central manager.
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            machinePendingState = .hardwareOn
        } else {
            callback.callback(message: .error(.bluetooth(central)))
        }
    }

    /// Handle discovering a peripheral.
    func centralManager(_: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData _: [String: Any],
                        rssi _: NSNumber) {
        print("Discovered peripheral")
        peripheral.delegate = self
        self.peripheral = peripheral
        centralManager?.connect(peripheral, options: nil)
        machinePendingState = .peripheralDiscovered
    }

    /// Handle connecting to a peripheral.
    func centralManager(_: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([serviceUuid])
        machinePendingState = .checkPeripheral
    }
}

extension MDocReaderBLECentral: CBPeripheralDelegate {
    /// Handle discovery of peripheral services.
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if error != nil {
            callback.callback(
                message: .error(.peripheral("Error discovering services: \(error!.localizedDescription)"))
            )
            return
        }
        if let services = peripheral.services {
            print("Discovered services")
            for service in services {
                peripheral.discoverCharacteristics(nil, for: service)
            }
        }
    }

    /// Handle discovery of characteristics for a peripheral service.
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if error != nil {
            callback.callback(
                message: .error(.peripheral("Error discovering characteristics: \(error!.localizedDescription)"))
            )
            return
        }
        if let characteristics = service.characteristics {
            print("Discovered characteristics")
            do {
                try processCharacteristics(peripheral: peripheral, characteristics: characteristics)
                machinePendingState = .awaitRequestStart
            } catch {
                callback.callback(message: .error(.peripheral("\(error)")))
                centralManager?.cancelPeripheralConnection(peripheral)
            }
        }
    }

    /// Handle a characteristic value being updated.
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        do {
            try processData(peripheral: peripheral, characteristic: characteristic)
        } catch {
            callback.callback(message: .error(.peripheral("\(error)")))
            centralManager?.cancelPeripheralConnection(peripheral)
        }
    }
  
    /// Notifies that the peripheral write buffer has space for more chunks.
    /// This is called after the buffer gets filled to capacity, and then has space again.
    ///
    /// Only available on iOS 11 and up.
    func peripheralIsReady(toSendWriteWithoutResponse _: CBPeripheral) {
        drainWritingQueue()
    }

    func peripheral(_: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: Error?) {
        if let error = error {
            print("Error opening l2cap channel - \(error.localizedDescription)")
            return
        }

        if let channel = channel {
            activeStream = MDocReaderBLECentralConnection(delegate: self, channel: channel)
        }
    }
}

extension MDocReaderBLECentral: CBPeripheralManagerDelegate {
    /// Handle peripheral manager state change.
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        switch peripheral.state {
        case .poweredOn:
            print("Peripheral Is Powered On.")
        case .unsupported:
            print("Peripheral Is Unsupported.")
        case .unauthorized:
            print("Peripheral Is Unauthorized.")
        case .unknown:
            print("Peripheral Unknown")
        case .resetting:
            print("Peripheral Resetting")
        case .poweredOff:
            print("Peripheral Is Powered Off.")
        @unknown default:
            print("Error")
        }
    }
}

extension MDocReaderBLECentral: MDocReaderBLECentralConnectionDelegate {
    func request(_ data: Data) {
        incomingMessageBuffer = data
        //machinePendingState = .l2capRequestReceived
    }

    func sendUpdate(bytes: Int, total: Int, fraction _: Double) {
        //callback.callback(message: .download(bytes, total))
    }

    func sendComplete() {
        machinePendingState = .complete
    }

    func connectionEnd() {}
}
