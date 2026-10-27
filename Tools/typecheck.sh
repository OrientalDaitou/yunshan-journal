#!/bin/zsh
# 没有完整 Xcode 时的替代检查：把 SwiftData 的 @Model / @Relationship 宏替换成存根，
# 其余所有源文件原样交给 swiftc 做完整类型检查。装好 Xcode 后请改用 xcodebuild。
set -e
ROOT="${0:A:h:h}"
WORK="${TMPDIR:-/tmp}/apt-typecheck"
rm -rf "$WORK" && mkdir -p "$WORK"
find "$ROOT/APT" -name '*.swift' -exec cp {} "$WORK/" \;
MODELS="$WORK/Models.swift"
sed -i '' -e '/^@Model$/d' -e '/^ *@Relationship(.*)$/d' "$MODELS"
for cls in $(grep -E '^final class [A-Za-z]+' "$MODELS" | sed -E 's/^final class ([A-Za-z]+).*/\1/'); do
cat >> "$MODELS" <<STUB

extension $cls: PersistentModel {
    var persistentBackingData: any BackingData<$cls> { get { fatalError() } set {} }
    static var schemaMetadata: [Schema.PropertyMetadata] { [] }
    convenience init(backingData: any BackingData<$cls>) { fatalError() }
}
STUB
done
# @Query 在 macOS 15 SDK 中也是宏：换成签名相同的属性包装器存根。
sed -i '' -e 's/@Query/@QueryStub/g' -e 's/= Query(/= QueryStub(/g' "$WORK"/*.swift
cat > "$WORK/_QueryStub.swift" <<'STUB'
import SwiftUI
import SwiftData
@propertyWrapper struct QueryStub<T: PersistentModel>: DynamicProperty {
    var wrappedValue: [T] { [] }
    init() {}
    init<V: Comparable>(sort: KeyPath<T, V>, order: SortOrder = .forward) {}
    init(_ descriptor: FetchDescriptor<T>) {}
    init(filter: Predicate<T>? = nil, sort: [SortDescriptor<T>] = []) {}
    init<V: Comparable>(filter: Predicate<T>?, sort: KeyPath<T, V>, order: SortOrder = .forward) {}
}
STUB
SDK="$(xcrun --show-sdk-path)"
swiftc -typecheck -parse-as-library -swift-version 5 -target arm64-apple-macos14.0 -sdk "$SDK" "$WORK"/*.swift
echo "类型检查通过（$(ls "$WORK"/*.swift | wc -l | tr -d ' ') 个文件）"
