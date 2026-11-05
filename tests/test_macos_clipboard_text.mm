#define RUSTADMIN_MACOS_CLIPBOARD_HELPERS_ONLY 1
#include "../src/platform/macos.mm"
#undef RUSTADMIN_MACOS_CLIPBOARD_HELPERS_ONLY

#import <objc/runtime.h>

#include <cassert>
#include <cstring>

@interface RemoteClipboardPromiseProvider : NSObject <NSPasteboardItemDataProvider>
@property(nonatomic, assign) BOOL requested;
@end

@implementation RemoteClipboardPromiseProvider

- (void)pasteboard:(NSPasteboard *)pasteboard
              item:(NSPasteboardItem *)item
 provideDataForType:(NSPasteboardType)type {
    (void)pasteboard;
    (void)item;
    (void)type;
    self.requested = YES;
}

@end

@interface ThrowingPasteboard : NSPasteboard
@end

@implementation ThrowingPasteboard

- (NSArray<NSPasteboardType> *)types {
    [NSException raise:@"RustAdminClipboardTestException" format:@"test exception"];
    return nil;
}

@end

static NSPasteboard *NewTestPasteboard() {
    NSPasteboard *pasteboard = [NSPasteboard pasteboardWithUniqueName];
    assert(pasteboard != nil);
    assert([pasteboard clearContents]);
    return pasteboard;
}

static void WriteItem(NSPasteboard *pasteboard, NSPasteboardItem *item) {
    assert([pasteboard writeObjects:@[item]]);
}

static void AssertCopy(NSPasteboard *pasteboard, const char *expected) {
    char *actual = MacPasteboardCopyPlainTextFromPasteboard(pasteboard);
    assert(actual != NULL);
    assert(strcmp(actual, expected) == 0);
    MacFreeCString(actual);
}

static void AssertNull(NSPasteboard *pasteboard) {
    char *actual = MacPasteboardCopyPlainTextFromPasteboard(pasteboard);
    assert(actual == NULL);
}

static void TestUrlFallback() {
    NSPasteboard *pasteboard = NewTestPasteboard();
    NSPasteboardItem *item = [[NSPasteboardItem alloc] init];
    [item setString:@"https://example.invalid/from-url" forType:NSPasteboardTypeURL];
    WriteItem(pasteboard, item);
    AssertCopy(pasteboard, "https://example.invalid/from-url");
}

static void TestPlainTextWinsOverUrl() {
    NSPasteboard *pasteboard = NewTestPasteboard();
    NSPasteboardItem *url_item = [[NSPasteboardItem alloc] init];
    [url_item setString:@"https://example.invalid/from-url" forType:NSPasteboardTypeURL];
    NSPasteboardItem *plain_item = [[NSPasteboardItem alloc] init];
    [plain_item setString:@"plain text wins" forType:NSPasteboardTypeString];
    assert(([pasteboard writeObjects:@[url_item, plain_item]]));
    AssertCopy(pasteboard, "plain text wins");

    NSPasteboard *empty_plain_pasteboard = NewTestPasteboard();
    NSPasteboardItem *empty_plain_item = [[NSPasteboardItem alloc] init];
    [empty_plain_item setString:@"https://example.invalid/nonempty-url" forType:NSPasteboardTypeURL];
    [empty_plain_item setString:@"" forType:NSPasteboardTypeString];
    WriteItem(empty_plain_pasteboard, empty_plain_item);
    AssertCopy(empty_plain_pasteboard, "https://example.invalid/nonempty-url");
}

static void TestUtf16AndMacRoman() {
    NSPasteboard *utf16_pasteboard = NewTestPasteboard();
    NSString *utf16_text = @"UTF-16 日本語 😀";
    NSData *with_bom = [utf16_text dataUsingEncoding:NSUTF16StringEncoding];
    assert([StringFromPlainTextPasteboardData(with_bom, @"public.utf16-external-plain-text")
        isEqualToString:utf16_text]);
    const uint8_t big_endian_bom[] = {0xfe, 0xff};
    NSMutableData *big_endian = [NSMutableData dataWithBytes:big_endian_bom length:2];
    [big_endian appendData:[utf16_text dataUsingEncoding:NSUTF16BigEndianStringEncoding]];
    assert([StringFromPlainTextPasteboardData(big_endian, @"public.utf16-external-plain-text")
        isEqualToString:utf16_text]);
    NSData *utf16_data = [utf16_text dataUsingEncoding:NSUTF16LittleEndianStringEncoding];
    [utf16_pasteboard declareTypes:@[@"public.utf16-external-plain-text"] owner:nil];
    [utf16_pasteboard setData:utf16_data forType:@"public.utf16-external-plain-text"];
    AssertCopy(utf16_pasteboard, "UTF-16 日本語 😀");

    NSPasteboard *mac_roman_pasteboard = NewTestPasteboard();
    NSString *mac_roman_text = @"Café";
    NSData *mac_roman_data = [mac_roman_text dataUsingEncoding:NSMacOSRomanStringEncoding];
    [mac_roman_pasteboard declareTypes:@[@"com.apple.traditional-mac-plain-text"] owner:nil];
    [mac_roman_pasteboard setData:mac_roman_data forType:@"com.apple.traditional-mac-plain-text"];
    AssertCopy(mac_roman_pasteboard, "Café");
}

static void TestUrlTitleAndFileRejection() {
    NSPasteboard *title_only_pasteboard = NewTestPasteboard();
    NSPasteboardItem *title_only_item = [[NSPasteboardItem alloc] init];
    [title_only_item setString:@"Display title" forType:@"public.url-name"];
    WriteItem(title_only_pasteboard, title_only_item);
    AssertNull(title_only_pasteboard);

    NSPasteboard *url_and_title_pasteboard = NewTestPasteboard();
    NSPasteboardItem *url_and_title_item = [[NSPasteboardItem alloc] init];
    [url_and_title_item setString:@"Display title" forType:@"public.url-name"];
    [url_and_title_item setString:@"https://example.invalid/actual-url" forType:NSPasteboardTypeURL];
    WriteItem(url_and_title_pasteboard, url_and_title_item);
    AssertCopy(url_and_title_pasteboard, "https://example.invalid/actual-url");

    NSPasteboard *file_url_pasteboard = NewTestPasteboard();
    NSPasteboardItem *file_url_item = [[NSPasteboardItem alloc] init];
    [file_url_item setString:@"file:///private/tmp/rustadmin-clipboard-test.txt" forType:NSPasteboardTypeURL];
    WriteItem(file_url_pasteboard, file_url_item);
    AssertNull(file_url_pasteboard);

    NSPasteboard *file_type_pasteboard = NewTestPasteboard();
    NSPasteboardItem *file_type_item = [[NSPasteboardItem alloc] init];
    [file_type_item setString:@"file:///private/tmp/rustadmin-clipboard-test.txt" forType:@"public.file-url"];
    WriteItem(file_type_pasteboard, file_type_item);
    AssertNull(file_type_pasteboard);

    NSPasteboard *filenames_pasteboard = NewTestPasteboard();
    NSPasteboardItem *filenames_item = [[NSPasteboardItem alloc] init];
    [filenames_item setPropertyList:@[@"/private/tmp/rustadmin-clipboard-test.txt"]
                            forType:@"NSFilenamesPboardType"];
    WriteItem(filenames_pasteboard, filenames_item);
    AssertNull(filenames_pasteboard);

    NSPasteboard *file_object_pasteboard = NewTestPasteboard();
    NSURL *file_url = [NSURL fileURLWithPath:@"/private/tmp/rustadmin-clipboard-test.txt"];
    assert([file_object_pasteboard writeObjects:@[file_url]]);
    AssertNull(file_object_pasteboard);
}

static void TestRemotePromiseAndExceptions() {
    NSPasteboard *remote_pasteboard = NewTestPasteboard();
    RemoteClipboardPromiseProvider *provider = [[RemoteClipboardPromiseProvider alloc] init];
    NSPasteboardItem *remote_item = [[NSPasteboardItem alloc] init];
    [remote_item setDataProvider:provider
                         forTypes:@[@"com.apple.is-remote-clipboard", NSPasteboardTypeString]];
    WriteItem(remote_pasteboard, remote_item);
    AssertNull(remote_pasteboard);
    assert(!provider.requested);

    AssertNull(nil);
    NSPasteboard *throwing_pasteboard = NewTestPasteboard();
    Class previous_class = object_setClass(throwing_pasteboard, [ThrowingPasteboard class]);
    assert(previous_class != Nil);
    assert(object_getClass(throwing_pasteboard) == [ThrowingPasteboard class]);
    AssertNull(throwing_pasteboard);
    Class replaced_class = object_setClass(throwing_pasteboard, previous_class);
    assert(replaced_class == [ThrowingPasteboard class]);
    assert(object_getClass(throwing_pasteboard) == previous_class);
}

int main() {
    @autoreleasepool {
        TestUrlFallback();
        TestPlainTextWinsOverUrl();
        TestUtf16AndMacRoman();
        TestUrlTitleAndFileRejection();
        TestRemotePromiseAndExceptions();
    }
    return 0;
}
