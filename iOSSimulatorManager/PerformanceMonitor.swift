import Foundation
import os.log

// 性能监控和日志系统
class PerformanceMonitor {
    static let shared = PerformanceMonitor()
    
    private let logger = Logger(subsystem: "com.ke.iOSSimulatorManager", category: "Performance")
    private var operationStartTimes: [String: Date] = [:]
    
    private init() {}
    
    /// 开始监控操作
    func startOperation(_ operationName: String) {
        operationStartTimes[operationName] = Date()
        logger.info("开始操作: \(operationName)")
    }
    
    /// 结束监控操作
    func endOperation(_ operationName: String) {
        guard let startTime = operationStartTimes[operationName] else {
            logger.warning("未找到操作开始时间: \(operationName)")
            return
        }
        
        let duration = Date().timeIntervalSince(startTime)
        operationStartTimes.removeValue(forKey: operationName)
        
        logger.info("操作完成: \(operationName), 耗时: \(String(format: "%.2f", duration))秒")
        
        // 性能警告
        if duration > 2.0 {
            logger.warning("性能警告: \(operationName) 耗时过长 (\(String(format: "%.2f", duration))秒)")
        }
    }
    
    /// 记录错误
    func logError(_ error: Error, operation: String = "") {
        if !operation.isEmpty {
            logger.error("操作错误 [\(operation)]: \(error.localizedDescription)")
        } else {
            logger.error("错误: \(error.localizedDescription)")
        }
    }
    
    /// 记录信息
    func logInfo(_ message: String) {
        logger.info("\(message)")
    }
    
    /// 记录调试信息
    func logDebug(_ message: String) {
        logger.debug("\(message)")
    }
}