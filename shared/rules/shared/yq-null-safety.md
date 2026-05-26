# yq Null-Safety Pattern

Every array op → (// []) guard. .field | join(",") crashes when field null/absent.

Pattern: (.field // []) | join(",")

❌ .tools | join(",")
✅ (.tools // []) | join(",")
