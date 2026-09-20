# Code conventions — Fash iOS

Quy ước bắt buộc cho **mọi agent và developer** khi sửa `Fash/**/*.swift`.  
Mục tiêu: tối đa hóa xác suất pass **iOS Release** (Xcode 26, WMO, ProdRelease) khi không build local.

> Checklist đầy đủ: [BUILD_CHECKLIST.md](./BUILD_CHECKLIST.md)  
> Validate tự động: `python scripts/validate_swift_syntax.py`

---

## 1. Nguyên tắc chung

1. **Đọc trước, viết sau** — mở 1–2 file cùng thư mục, copy pattern.
2. **Diff nhỏ** — không refactor ngoài scope task.
3. **Android parity** — UI/VM đối chiếu Kotlin cùng feature (`fash-android-mobile`).
4. **Không file Swift mới ngoài `Fash/`** — XcodeGen quét `project.yml`, không sửa pbxproj tay.
5. **Không markdown trong Swift** — không để `` ` `` hoặc ` ``` ` thừa cuối file (đã fail build 49).

---

## 2. Cú pháp Swift (script bắt được)

| Rule | ❌ Sai | ✅ Đúng |
|------|--------|---------|
| `guard` | `guard x { return }` | `guard x else { return }` |
| Trailing comma (Swift 5.9) | `foo(a, b,)` trước `)` | `foo(a, b)` |
| Token theme | `FashTypography.headingX` (không tồn tại) | token trong `FashTypography.swift` |
| Cân bằng `{}` | thiếu `}` | đếm brace trước commit |
| Duplicate `func` cùng signature | hai `func load()` giống nhau | gộp hoặc đổi tên |
| Duplicate top-level helper | hai `parsePositiveLong` cùng file/module private | một định nghĩa duy nhất |

---

## 3. Access control & extensions

`private` = **file-scoped**, không phải type-scoped.

- ❌ `Type.swift` gọi `private func` từ `Type+Ext.swift`
- ✅ Helper dùng chung → `internal` / file chung / bỏ `private`
- ❌ `internal func` trả về `private struct`
- ✅ Cùng file hoặc nâng access level type

**Extensions trùng:**

- ❌ `private extension CommonAestheticTagDto { func displayLabel() }` ở nhiều file
- ✅ Dùng [AestheticTagLabels.swift](../Fash/data/common/AestheticTagLabels.swift)

---

## 4. Concurrency & MainActor

- Mutate `AppRouter`, `@Observable` VM, UI state → `@MainActor` hoặc `await MainActor.run { }`
- Enum navigation helper → `@MainActor enum AppPromoNavigation`
- Closure lưu vào property → tham số `@escaping`
- Optional closure `(() -> Void)?` → **không** viết `(@escaping () -> Void)?`

**UIKit completion:**

```swift
// ❌ Swift infer () -> Task<(), Never>
let deliver = { Task { ... } }

// ✅
let deliver: () -> Void = { Task { ... } }
```

---

## 5. Optional & parsing

| Tình huống | ✅ Pattern |
|-----------|-----------|
| `RepositoryHttp.optString` | `String` non-optional — check `.isEmpty` |
| `.nilIfEmpty` | Gọi trên `String`, không chain sai sau `flatMap` |
| `String?` method | `value?.trimmingCharacters(...)` |
| `prefix` → `String(format:)` | `String(value.prefix(n))` |
| Case compare | `a.caseInsensitiveCompare(b) != .orderedSame` |

Parser: dùng `RepositoryHttp.optString/optLong/optBool`, đối chiếu Android repository cho JSON keys.

---

## 6. SwiftUI

### ViewBuilder & return type

Hàm dùng trong `VStack { previewRow(...) }` **phải** return `some View`:

```swift
// ❌
private func previewRow(...) { PreviewEditRow(...) }

// ✅
private func previewRow(...) -> some View { PreviewEditRow(...) }
```

### Recursive / opaque type

Lazy tree/category đệ quy dễ **“defines opaque type in terms of itself”**:

```swift
// ❌ @ViewBuilder private func section(...) -> some View { if ... ForEach { section(...) } }

// ✅
private func section(...) -> AnyView { ... return AnyView(VStack { ... }) }
```

### Type names (module-level)

| Đã tồn tại | Ghi chú |
|------------|---------|
| `FlowLayout` | `ProfileComponents.swift` — dùng lại, không copy |
| `CommonAestheticTagDto.displayLabel()` | `AestheticTagLabels.swift` |

### Scroll / masonry

- Trong `ScrollView` + `LazyVStack`: dùng `ListingMasonryLazyRows`, **không** nested `LazyVStack` cột
- Home feed: dùng `FeedMasonryWindowedGrid` (logical feed không bao giờ trim, không scroll compensation) — xem [HOME_FEED_MASONRY.md](./HOME_FEED_MASONRY.md)
- Footer listing: không `frame(height:)` cố định cắt text

### iOS 17 APIs

`AnimatedContent` — nếu dùng, bọc `#available(iOS 17, *)` + fallback iOS 17.  
Release WMO đôi khi fail ngay cả khi có availability — **ưu tiên** `.animation` + `.id()` đơn giản.

### Type-check timeout

View phức tạp (`FashWaitingScreen`, grid lớn): tách subview, precompute `let x = ...` ngoài builder.

---

## 7. Localization

Key mới **bắt buộc** cả 3:

1. `vendor/android-res/values/strings.xml` + `values-en/`
2. `Fash/Resources/{vi,en}.lproj/Localizable.strings`
3. `Fash/Localization/L10n.swift`

Không invent `L10n.*` không có trong vendor.

---

## 8. Post / Explore / Feed — pattern đã verify

| Area | Pattern |
|------|---------|
| Explore listing tap | `deps.presentListingPreview(...)` — không PDP trực tiếp trên overlay |
| Explore scroll chrome | Header trong ScrollView; sticky overlay khi scroll > 88pt |
| Post slider binding | `set: { newValue in postVM.updateDraft { ... } }` — không `$0` nhầm với draft |
| Post price helper | Một `parsePositiveLong` trong `PostListingHelpers.swift` hoặc `CreateListingDraft.swift` |

---

## 9. Commit message

```
<type>: <short summary>

<body optional — why, not what>
```

Types: `feat`, `fix`, `refactor`, `release`, `ci`, `docs`

Release: `Release 1.0.13 (53): Explore UX, listing cards`

---

## 10. Incident log (thêm rule khi gặp)

| Incident | Rule |
|----------|------|
| Build 49: `` ` `` cuối `FashPromoMetrics.swift` | Không ký tự markdown trong `.swift` |
| Build 50–51: post flow | ViewBuilder return type, duplicate extensions |
| Build 52: `AnimatedContent` | Fallback animation không iOS 17-only |
| Build 53: duplicate helper, share dismiss, waiting type-check | Xem §3–6 |

**Khi fix incident mới:** thêm dòng vào bảng này + script nếu có thể.

---

## Tham chiếu file theme / kiến trúc

| File | Dùng cho |
|------|----------|
| `Fash/ui/theme/FashTypography.swift` | Font tokens |
| `Fash/ui/theme/Color.swift` | `FashColors.*` |
| `Fash/data/common/RepositoryHttp.swift` | JSON helpers |
| `IOS_ARCHITECTURE.md` | Layers, router |
