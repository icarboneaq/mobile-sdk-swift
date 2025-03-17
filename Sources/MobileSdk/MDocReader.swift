import CoreBluetooth
import SpruceIDMobileSdkRs

public class MDocReader: MDocBLEDelegate, MDocReaderBLECentralDelegate {
    func updateForCentralClientMode(message: MDocReaderBLECallback) {
        print(message)
    }
    
    func callback(message: MDocBLECallback) {
        print(message)
    }
    
    var sessionManager: MdlSessionManager
    var bleManager: MDocReaderBLECentral!
    var callback: BLESessionStateDelegate

    public init?(
        callback: BLESessionStateDelegate,
        uri: String,
        requestedItems: [String: [String: Bool]],
        trustAnchorRegistry: [String]?
    ) {
        self.callback = callback
        do {
            let sessionData = try SpruceIDMobileSdkRs.establishSession(uri: uri,
                                                                       requestedItems: requestedItems,
                                                                       trustAnchorRegistry: trustAnchorRegistry)
            self.sessionManager = sessionData.state
            self.bleManager = MDocReaderBLECentral(callback: self,
                                                   request: sessionData.request,
                                                   serviceUuid: CBUUID(string: sessionData.uuid),
                                                   useL2CAP: false)
        } catch {
            print("\(error)")
            return nil
        }
    }

    public func cancel() {
        //bleManager.disconnect()
    }
}

extension MDocReader: MDocReaderBLEPeripheralDelegate {
    func updateForPeripheralServerMode(message: MDocReaderBLECallback) {
        print(message)
    }
    
    func callback(message: MDocReaderBLECallback) {
        print(message)
        switch message {
        case .done(let data): break
            //self.callback.update(state: .success(.item(data)))
        case .connected:
            self.callback.update(state: .connected)
        case .error(let error):
            //self.callback.update(state: .error(BleReaderSessionError(readerBleError: error)))
            self.cancel()
        case .message(let data):
            do {
                let stringData = String(data: data, encoding: .utf8)
                let str = String(decoding: data, as: UTF8.self)
                let data = Data(bytes: data)
                let base64 = data.base64EncodedUrlSafe
                let responseData = try SpruceIDMobileSdkRs.handleResponse(state: self.sessionManager, response: data)
                self.sessionManager = responseData.state
                //self.callback.update(state: .success(.mdlReaderResponseData(responseData)))
            } catch {
                self.callback.update(state: .error(.generic("\(error)")))
                self.cancel()
            }
        case .downloadProgress(let index): break
            //self.callback.update(state: .downloadProgress(index))
        }
    }
}

/// To be implemented by the consumer to update the UI
public protocol BLEReaderSessionStateDelegate: AnyObject {
    func update(state: BLEReaderSessionState)
}

public enum BLEReaderSessionState {
    /// App should display the error message
    case error(BleReaderSessionError)
    /// App should indicate to the reader is waiting to connect to the holder
    case advertizing
    /// App should indicate to the user that BLE connection has been established
    case connected
    /// App should display the fact that a certain amount of data has been received
    /// - Parameters:
    ///   - 0: The number of chunks received to far
    case downloadProgress(Int)
    /// App should display a success message and offer to close the page
    case success(BLEReaderSessionStateSuccess)
}

public enum BLEReaderSessionStateSuccess {
    case item([String: [String: MDocItem]])
    case mdlReaderResponseData(MdlReaderResponseData)
}

public enum BleReaderSessionError {
    /// When communication with the server fails
    case server(String)
    /// When Bluetooth is unusable (e.g. unauthorized).
    case bluetooth(CBCentralManager)
    /// Generic unrecoverable error
    case generic(String)

    init(readerBleError: MdocReaderBleError) {
        switch readerBleError {
        case .peripheral(let string):
            self = .generic(string)
        case .server(let string):
            self = .server(string)
        case .bluetooth(let string):
            self = .bluetooth(string)
        }
    }
}
