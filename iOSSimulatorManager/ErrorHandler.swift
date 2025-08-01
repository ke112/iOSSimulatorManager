import Foundation

// 错误类型定义
enum SimulatorError: Error, LocalizedError {
    case commandExecutionFailed(String)
    case deviceNotFound(String)
    case jsonDecodingFailed
    case xcrunNotFound
    
    var errorDescription: String? {
        switch self {
        case .commandExecutionFailed(let message):
            return "命令执行失败: \(message)"
        case .deviceNotFound(let udid):
            return "未找到设备: \(udid)"
        case .jsonDecodingFailed:
            return "设备信息解析失败"
        case .xcrunNotFound:
            return "未找到Xcode命令行工具"
        }
    }
}

// 错误处理协议
protocol ErrorHandler {
    func handleError(_ error: Error)
}