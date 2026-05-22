#if !canImport(OSLog)
public enum OSLogPrivacy: Sendable {
    case `public`
    case `private`
}

public struct Logger: Sendable {
    public init(subsystem: String, category: String) {}

    public func debug(_ message: @autoclosure () -> LoggerMessage) {}
    public func info(_ message: @autoclosure () -> LoggerMessage) {}
    public func notice(_ message: @autoclosure () -> LoggerMessage) {}
    public func warning(_ message: @autoclosure () -> LoggerMessage) {}
    public func error(_ message: @autoclosure () -> LoggerMessage) {}
    public func critical(_ message: @autoclosure () -> LoggerMessage) {}
}

public struct LoggerMessage: ExpressibleByStringInterpolation, ExpressibleByStringLiteral, Sendable {
    public init(stringLiteral value: String) {}
    public init(stringInterpolation: StringInterpolation) {}

    public struct StringInterpolation: StringInterpolationProtocol, Sendable {
        public init(literalCapacity: Int, interpolationCount: Int) {}

        public mutating func appendLiteral(_ literal: String) {}

        public mutating func appendInterpolation<T>(_ value: T) {}

        public mutating func appendInterpolation<T>(
            _ value: T,
            privacy: OSLogPrivacy
        ) {}
    }
}
#endif
