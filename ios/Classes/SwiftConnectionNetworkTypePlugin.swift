import Flutter
import UIKit
import Reachability
import CoreTelephony

private struct NetworkTypes {
  static let unreachable = "unreach"
  static let wifi = "wifi"
  static let mobile2G = "mobile2G"
  static let mobile3G = "mobile3G"
  static let mobile4G = "mobile4G"
  static let mobile5G = "mobile5G"
  static let otherMobile = "mobileOther"
}

public class SwiftConnectionNetworkTypePlugin: NSObject, FlutterPlugin {
  private func startNetworkPolling() {
    stopNetworkPolling()
    
    DispatchQueue.main.async { [weak self] in
      self?.networkPollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
        self?.checkAndUpdateNetworkStatus()
      }
    }
  }


  private func stopNetworkPolling() {
    DispatchQueue.main.async { [weak self] in
      self?.networkPollTimer?.invalidate()
      self?.networkPollTimer = nil
    }
  }

  @objc private func checkAndUpdateNetworkStatus() {
    if let sink = eventSink {
      let currentStatus = statusForNetWork()

      if currentStatus != lastStatus {
        print("Network status changed from polling: \(String(describing: lastStatus)) to \(currentStatus)")
        lastStatus = currentStatus
        sink(currentStatus)
      }
    }
  }

  deinit {
    if reachability != nil {
      reachability?.stopNotifier()
      reachability = nil
    }
    stopNetworkPolling()
    NotificationCenter.default.removeObserver(self)
  }
  
  public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
    if reachability != nil {
      reachability?.stopNotifier()
      reachability = nil
    }
    stopNetworkPolling()
    NotificationCenter.default.removeObserver(self)
  }
  
  private var reachability: Reachability?
  private var eventSink: FlutterEventSink?
  private var lastStatus: String?
  private var lastNotificationTime: Date = Date.distantPast
  private var networkPollTimer: Timer?
  private static var pluginInstance: SwiftConnectionNetworkTypePlugin?
  
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "connection_network_type", binaryMessenger: registrar.messenger())
    let instance = SwiftConnectionNetworkTypePlugin()
    pluginInstance = instance
    registrar.addMethodCallDelegate(instance, channel: channel)

    let streamChannel = FlutterEventChannel(name: "connection_network_type_status", binaryMessenger: registrar.messenger())
    streamChannel.setStreamHandler(instance)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    if call.method == "networkStatus" {
      result(statusForNetWork())
    } else {
      result(FlutterMethodNotImplemented)
    }
  }
}

extension SwiftConnectionNetworkTypePlugin: FlutterStreamHandler {
  public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    // Remove existing observer before starting
    NotificationCenter.default.removeObserver(self, name: .reachabilityChanged, object: nil)
    
    // Add notification observer
    NotificationCenter.default.addObserver(self, selector:#selector(networkStatusChange(_:)), name: .reachabilityChanged, object: nil)

    if reachability != nil {
      reachability?.stopNotifier()
      reachability = nil
    }
    
    do {
      let newReachability = try Reachability()
      newReachability.allowsCellularConnection = true
      try newReachability.startNotifier()
      reachability = newReachability

      let status = statusForNetWork()
      lastStatus = status
      events(status)
      
      // Start polling
      startNetworkPolling()
    } catch {
      return FlutterError(code: "UNAVAILABLE", message: "Network monitoring unavailable", details: "Failed to initialize network monitoring: \(error.localizedDescription)");
    }
    
    eventSink = events
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    if reachability != nil {
      reachability?.stopNotifier() // NLE: stop the notifier when cancelling
      reachability = nil
    }
    stopNetworkPolling()
    NotificationCenter.default.removeObserver(self)
    return nil
  }


  @objc func networkStatusChange(_ notice: Notification) {
    if let reachability = notice.object as? Reachability, let sink = eventSink {
      let currentStatus = statusForNetWork()
      
      // Duplicate check
      if currentStatus != lastStatus {
        lastStatus = currentStatus
        sink(currentStatus)
      }
    }
  }

  private func statusForNetWork() -> String {
    // 0:unreachable 1:2G 2:3G 3:Wi-Fi 4:4G 5:5G 6:othermobie
    if reachability == nil {
      do {
        let newReachability = try Reachability()
        try newReachability.startNotifier()
        reachability = newReachability
      } catch {
        return NetworkStatus.unreach.value // Return unreachable if we couldn't initialize
      }
    }
    guard let netReach = reachability else { return NetworkStatus.unreach.value }
    switch netReach.connection {
    case .wifi:
      return NetworkStatus.wifi.value
    case .unavailable:
      return NetworkStatus.unreach.value
    case .cellular:
        do {
          let teleInfo = CTTelephonyNetworkInfo()
          var radioTech: String? = nil

          // 1. 5G
          // 2. 4G
          // 3. 3G
          // 4. 2G
          // 5. Unclassified
          
          if #available(iOS 12.0, *) {
            // iOS 12+ uses serviceCurrentRadioAccessTechnology for multiple carriers
            if let techDict = teleInfo.serviceCurrentRadioAccessTechnology, !techDict.isEmpty {

              // 5G
              if #available(iOS 14.1, *) {
                for tech in techDict.values {
                  if tech == CTRadioAccessTechnologyNR || tech == CTRadioAccessTechnologyNRNSA {
                    return NetworkStatus.mobile5G.value
                  }
                }
              }
              
              // 4G
              for tech in techDict.values {
                if tech == CTRadioAccessTechnologyLTE {
                  return NetworkStatus.mobile4G.value
                }
              }
              
              // 3G
              let tech3G = [CTRadioAccessTechnologyHSDPA,
                          CTRadioAccessTechnologyWCDMA,
                          CTRadioAccessTechnologyHSUPA,
                          CTRadioAccessTechnologyCDMAEVDORev0,
                          CTRadioAccessTechnologyCDMAEVDORevA,
                          CTRadioAccessTechnologyCDMAEVDORevB,
                          CTRadioAccessTechnologyeHRPD]
              
              for tech in techDict.values {
                if tech3G.contains(tech) {
                  return NetworkStatus.mobile3G.value
                }
              }
              
              // 2G
              let tech2G = [CTRadioAccessTechnologyEdge,
                          CTRadioAccessTechnologyGPRS,
                          CTRadioAccessTechnologyCDMA1x]
              
              for tech in techDict.values {
                if tech2G.contains(tech) {
                  return NetworkStatus.mobile2G.value
                }
              }
              
              // Unclassified
              if let firstTech = techDict.values.first {
                radioTech = firstTech
              }
            } else {
              print("No serviceCurrentRadioAccessTechnology information available")
            }
          } else {
            // iOS 11 and earlier
            if let tech = teleInfo.currentRadioAccessTechnology {
              radioTech = tech
            } else {
              print("No currentRadioAccessTechnology information available")
            }
          }

          if let tech = radioTech {
            // 2G
            if [CTRadioAccessTechnologyEdge, CTRadioAccessTechnologyGPRS, CTRadioAccessTechnologyCDMA1x].contains(tech) {
              return NetworkStatus.mobile2G.value
            }
            
            // 3G
            if [CTRadioAccessTechnologyHSDPA, CTRadioAccessTechnologyWCDMA, CTRadioAccessTechnologyHSUPA,
                CTRadioAccessTechnologyCDMAEVDORev0, CTRadioAccessTechnologyCDMAEVDORevA,
                CTRadioAccessTechnologyCDMAEVDORevB, CTRadioAccessTechnologyeHRPD].contains(tech) {
              return NetworkStatus.mobile3G.value
            }
            
            // 4G - LTE
            if tech == CTRadioAccessTechnologyLTE {
              return NetworkStatus.mobile4G.value
            }
            
            // 5G - NR and NR NSA
            if #available(iOS 14.1, *), tech == CTRadioAccessTechnologyNR || tech == "NRNSAMode" {
              return NetworkStatus.mobile5G.value
            }
          } else {
            print("No radio technology information available, but cellular connection detected")
          }
          
          // If we cant determine the network return other
          return NetworkStatus.other.value
        } catch {
          return NetworkStatus.other.value
        }
    default:
      return NetworkStatus.unreach.value
    }
  }

  enum NetworkStatus: String {
    case unreach = "unreach"
    case mobile2G = "mobile2G"
    case mobile3G = "mobile3G"
    case wifi = "wifi"
    case mobile4G = "mobile4G"
    case mobile5G = "mobile5G"
    case other = "mobileOther"
    var value: String{
      return self.rawValue
    }
  }
}