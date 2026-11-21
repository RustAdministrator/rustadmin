#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../libs/clipboard/src/windows/wf_cliprdr.c"

static SIZE_T descriptor_size(UINT count)
{
	return offsetof(FILEGROUPDESCRIPTORW, fgd) + (SIZE_T)count * sizeof(FILEDESCRIPTORW);
}

static int check_bool(const char *name, BOOL actual, BOOL expected)
{
	if (actual == expected)
		return 0;
	fprintf(stderr, "%s: expected %d, got %d\n", name, expected, actual);
	return 1;
}

static int test_descriptor_size_rejects_buffer_smaller_than_header(void)
{
	int failed = 0;
	failed += check_bool("rejects empty buffer",
						 wf_cliprdr_file_group_descriptor_size_valid(0, 1), FALSE);
	failed += check_bool(
		"rejects buffer smaller than fixed header",
		wf_cliprdr_file_group_descriptor_size_valid(offsetof(FILEGROUPDESCRIPTORW, fgd) - 1, 1),
		FALSE);
	return failed;
}

static int test_descriptor_size_rejects_zero_items(void)
{
	return check_bool(
		"rejects zero items",
		wf_cliprdr_file_group_descriptor_size_valid(offsetof(FILEGROUPDESCRIPTORW, fgd), 0),
		FALSE);
}

static int test_descriptor_size_accepts_max_stream_count(void)
{
	return check_bool(
		"accepts max stream count",
		wf_cliprdr_file_group_descriptor_size_valid(descriptor_size(WF_CLIPRDR_MAX_STREAMS),
													WF_CLIPRDR_MAX_STREAMS),
		TRUE);
}

static int test_descriptor_size_rejects_stream_count_above_limit(void)
{
	return check_bool(
		"rejects stream count above limit",
		wf_cliprdr_file_group_descriptor_size_valid(descriptor_size(WF_CLIPRDR_MAX_STREAMS),
													WF_CLIPRDR_MAX_STREAMS + 1),
		FALSE);
}

static int test_descriptor_size_rejects_truncated_descriptor_array(void)
{
	return check_bool(
		"rejects truncated descriptor array",
		wf_cliprdr_file_group_descriptor_size_valid(descriptor_size(2) - 1, 2), FALSE);
}

static int test_descriptor_size_rejects_extreme_count(void)
{
	return check_bool("rejects extreme count",
					  wf_cliprdr_file_group_descriptor_size_valid((SIZE_T)-1, (UINT)-1), FALSE);
}


static wfClipboard *new_test_clipboard(void)
{
	wfClipboard *clipboard = (wfClipboard *)calloc(1, sizeof(wfClipboard));

	if (!clipboard)
		return NULL;
	clipboard->map_capacity = 32;
	clipboard->format_mappings =
		(formatMapping *)calloc(clipboard->map_capacity, sizeof(formatMapping));
	if (!clipboard->format_mappings)
	{
		free(clipboard);
		return NULL;
	}
	return clipboard;
}

static void free_test_clipboard(wfClipboard *clipboard)
{
	if (!clipboard)
		return;
	clear_format_map(clipboard);
	free(clipboard->format_mappings);
	free(clipboard);
}

static int check_size(const char *name, size_t actual, size_t expected)
{
	if (actual == expected)
		return 0;
	fprintf(stderr, "%s: expected %zu, got %zu\n", name, expected, actual);
	return 1;
}

static int slots_are_zero(const wfClipboard *clipboard, size_t from, size_t to)
{
	static const formatMapping zero = { 0 };
	size_t i;

	for (i = from; i < to; i++)
	{
		if (memcmp(&clipboard->format_mappings[i], &zero, sizeof(zero)) != 0)
			return 0;
	}
	return 1;
}

static int test_format_map_growth_zeroes_new_slots_and_is_bounded(void)
{
	static const size_t targets[] = { 33, 64, WF_CLIPRDR_MAX_FORMATS };
	int failed = 0;
	size_t t;

	for (t = 0; t < sizeof(targets) / sizeof(targets[0]); t++)
	{
		wfClipboard *clipboard = new_test_clipboard();

		if (!clipboard)
			return failed + 1;
		failed += check_bool("grows to target", map_ensure_capacity(clipboard, targets[t]), TRUE);
		failed += check_size("capacity after growth", clipboard->map_capacity, targets[t]);
		failed += check_bool("new slots are zeroed", slots_are_zero(clipboard, 32, targets[t]), TRUE);
		/* Freeing every slot after growth must only ever see NULL names. */
		failed += check_bool("clear after growth", clear_format_map(clipboard), TRUE);
		free_test_clipboard(clipboard);
	}

	{
		wfClipboard *clipboard = new_test_clipboard();

		if (!clipboard)
			return failed + 1;
		failed += check_bool("rejects one above the limit",
							 map_ensure_capacity(clipboard, WF_CLIPRDR_MAX_FORMATS + 1), FALSE);
		failed += check_bool("rejects an extreme capacity",
							 map_ensure_capacity(clipboard, (size_t)-1), FALSE);
		failed += check_size("capacity unchanged after rejection", clipboard->map_capacity, 32);
		failed += check_bool("no growth needed", map_ensure_capacity(clipboard, 16), TRUE);
		failed += check_bool("rejects a missing clipboard", map_ensure_capacity(NULL, 33), FALSE);
		free_test_clipboard(clipboard);
	}
	return failed;
}

static int test_bounded_strlen_stops_at_the_limit(void)
{
	size_t len = 0;
	char unterminated[8];
	int failed = 0;

	memset(unterminated, 'a', sizeof(unterminated));
	failed += check_bool("measures a short string", wf_cliprdr_bounded_strlen("abc", 255, &len), TRUE);
	failed += check_size("short string length", len, 3);
	failed += check_bool("accepts a string of exactly the limit",
						 wf_cliprdr_bounded_strlen("abcd", 4, &len), TRUE);
	failed += check_bool("rejects a string longer than the limit",
						 wf_cliprdr_bounded_strlen("abcde", 4, &len), FALSE);
	failed += check_bool("does not read past an unterminated buffer within the limit",
						 wf_cliprdr_bounded_strlen(unterminated, 3, &len), FALSE);
	failed += check_bool("rejects NULL input", wf_cliprdr_bounded_strlen(NULL, 4, &len), FALSE);
	failed += check_bool("rejects NULL output", wf_cliprdr_bounded_strlen("abc", 4, NULL), FALSE);
	return failed;
}

static int test_format_list_rejects_oversized_lists_and_names(void)
{
	wfClipboard *clipboard = new_test_clipboard();
	CliprdrClientContext context;
	CLIPRDR_FORMAT_LIST list;
	CLIPRDR_FORMAT *formats;
	char long_name[301];
	int failed = 0;

	if (!clipboard)
		return 1;
	formats = (CLIPRDR_FORMAT *)calloc(WF_CLIPRDR_MAX_FORMATS + 1, sizeof(CLIPRDR_FORMAT));
	if (!formats)
	{
		free_test_clipboard(clipboard);
		return 1;
	}
	ZeroMemory(&context, sizeof(context));
	context.Custom = clipboard;
	ZeroMemory(&list, sizeof(list));

	/* One entry more than the registered-format range allows. */
	list.numFormats = WF_CLIPRDR_MAX_FORMATS + 1;
	list.formats = formats;
	failed += check_size("oversize list is rejected",
						 wf_cliprdr_server_format_list(&context, &list), ERROR_INTERNAL_ERROR);
	failed += check_bool("oversize list publishes nothing", clipboard->copied, FALSE);
	failed += check_size("oversize list leaves the map empty", clipboard->map_size, 0);

	/* A count without any entries behind it. */
	list.numFormats = 1;
	list.formats = NULL;
	failed += check_size("missing entries are rejected",
						 wf_cliprdr_server_format_list(&context, &list), ERROR_INTERNAL_ERROR);
	failed += check_bool("missing entries publish nothing", clipboard->copied, FALSE);

	/* A format name longer than a registered clipboard format name may be. */
	memset(long_name, 'a', sizeof(long_name) - 1);
	long_name[sizeof(long_name) - 1] = '\0';
	formats[0].formatId = 0xC001;
	formats[0].formatName = long_name;
	list.numFormats = 1;
	list.formats = formats;
	failed += check_size("overlong format name is rejected",
						 wf_cliprdr_server_format_list(&context, &list), ERROR_INTERNAL_ERROR);
	failed += check_bool("overlong format name publishes nothing", clipboard->copied, FALSE);
	failed += check_size("overlong format name leaves the map empty", clipboard->map_size, 0);

	free(formats);
	free_test_clipboard(clipboard);
	return failed;
}

static CLIPRDR_FILE_CONTENTS_RESPONSE make_response(UINT32 connID, UINT32 streamId, BYTE *data, UINT32 size)
{
	CLIPRDR_FILE_CONTENTS_RESPONSE response;

	ZeroMemory(&response, sizeof(response));
	response.connID = connID;
	response.streamId = streamId;
	response.msgFlags = CB_RESPONSE_OK;
	response.cbRequested = size;
	response.requestedData = data;
	return response;
}

static int test_file_contents_response_answers_only_the_outstanding_request(void)
{
	wfClipboard *clipboard = new_test_clipboard();
	CliprdrClientContext context;
	BYTE payload[4] = { 1, 2, 3, 4 };
	CLIPRDR_FILE_CONTENTS_RESPONSE response;
	char *first;
	int failed = 0;

	if (!clipboard)
		return 1;
	ZeroMemory(&context, sizeof(context));
	context.Custom = clipboard;
	clipboard->req_fevent = CreateEventW(NULL, TRUE, FALSE, NULL);
	if (!clipboard->req_fevent)
	{
		free_test_clipboard(clipboard);
		return 1;
	}
	clipboard->req_f_conn_id_expected = 7;
	clipboard->req_f_stream_id_expected = 3;

	/* No request is outstanding: dropped without touching req_fdata or waking a waiter. */
	response = make_response(7, 3, payload, sizeof(payload));
	clipboard->req_f_pending = 0;
	failed += check_size("unsolicited response is acknowledged",
						 wf_cliprdr_server_file_contents_response(&context, &response), CHANNEL_RC_OK);
	failed += check_bool("unsolicited response stores nothing", clipboard->req_fdata == NULL, TRUE);
	failed += check_bool("unsolicited response does not signal the waiter",
						 WaitForSingleObject(clipboard->req_fevent, 0) == WAIT_TIMEOUT, TRUE);

	/* A response for another stream or another connection keeps the request pending. */
	clipboard->req_f_pending = 1;
	response = make_response(7, 4, payload, sizeof(payload));
	wf_cliprdr_server_file_contents_response(&context, &response);
	response = make_response(8, 3, payload, sizeof(payload));
	wf_cliprdr_server_file_contents_response(&context, &response);
	failed += check_bool("foreign stream/connection stores nothing", clipboard->req_fdata == NULL, TRUE);
	failed += check_size("foreign response leaves the request pending", (size_t)clipboard->req_f_pending, 1);

	/* The matching response is accepted exactly once. */
	response = make_response(7, 3, payload, sizeof(payload));
	failed += check_size("matching response succeeds",
						 wf_cliprdr_server_file_contents_response(&context, &response), CHANNEL_RC_OK);
	failed += check_bool("matching response stores the data", clipboard->req_fdata != NULL, TRUE);
	failed += check_size("matching response records its size", clipboard->req_fsize, sizeof(payload));
	failed += check_size("matching response completes the request", (size_t)clipboard->req_f_pending, 0);
	first = clipboard->req_fdata;

	/* A repeated response must not replace the buffer (which would leak it). */
	wf_cliprdr_server_file_contents_response(&context, &response);
	failed += check_bool("repeated response keeps the first buffer", clipboard->req_fdata == first, TRUE);

	free(first);
	clipboard->req_fdata = NULL;
	CloseHandle(clipboard->req_fevent);
	free_test_clipboard(clipboard);
	return failed;
}

static UINT16 captured_format_flags = 0xffff;
static UINT32 captured_format_len = 0xffffffff;
static int captured_format_responses = 0;

static UINT capture_format_data_response(CliprdrClientContext *context,
										 const CLIPRDR_FORMAT_DATA_RESPONSE *response)
{
	(void)context;
	captured_format_responses++;
	captured_format_flags = response->msgFlags;
	captured_format_len = response->dataLen;
	return 0;
}

/* Puts a text into the clipboard of this window station. FALSE when that is not possible here. */
static BOOL set_clipboard_text(const WCHAR *text, SIZE_T bytes)
{
	HGLOBAL mem;
	void *p;

	if (!OpenClipboard(NULL))
		return FALSE;
	EmptyClipboard();
	mem = GlobalAlloc(GMEM_MOVEABLE, bytes);
	p = mem ? GlobalLock(mem) : NULL;
	if (!p)
	{
		CloseClipboard();
		return FALSE;
	}
	memcpy(p, text, bytes);
	GlobalUnlock(mem);
	if (!SetClipboardData(CF_UNICODETEXT, mem))
	{
		CloseClipboard();
		return FALSE;
	}
	CloseClipboard();
	return TRUE;
}

/* The peer may ask for the list of files and nothing else. A request for another format id,
 * such as text, used to be answered with whatever the user had in the clipboard. */
static int test_format_data_request_is_answered_for_files_only(void)
{
	static const WCHAR marker[] = L"clipboard text of the user";
	wfClipboard *clipboard = new_test_clipboard();
	CliprdrClientContext context;
	CLIPRDR_FORMAT_DATA_REQUEST request;
	int failed = 0;

	if (!clipboard)
		return 1;
	ZeroMemory(&context, sizeof(context));
	context.Custom = clipboard;
	context.EnableOthers = FALSE;
	context.ClientFormatDataResponse = capture_format_data_response;
	clipboard->context = &context;
	if (!set_clipboard_text(marker, sizeof(marker)))
		printf("note: no clipboard in this session; the request is still refused before it is read\n");

	ZeroMemory(&request, sizeof(request));
	request.connID = 1;
	request.requestedFormatId = CF_UNICODETEXT;
	captured_format_responses = 0;
	failed += check_bool("text request is refused",
						 wf_cliprdr_server_format_data_request(&context, &request) != ERROR_SUCCESS, TRUE);
	failed += check_size("text request gets one response", (size_t)captured_format_responses, 1);
	failed += check_size("text request gets a failure response", captured_format_flags, CB_RESPONSE_FAIL);
	failed += check_size("text request gets no data", captured_format_len, 0);

	request.requestedFormatId = CF_HDROP;
	captured_format_responses = 0;
	wf_cliprdr_server_format_data_request(&context, &request);
	failed += check_size("any other format gets a failure response", captured_format_flags, CB_RESPONSE_FAIL);
	failed += check_size("any other format gets no data", captured_format_len, 0);

	free_test_clipboard(clipboard);
	return failed;
}

static UINT16 captured_contents_flags = 0xffff;
static UINT32 captured_contents_size = 0xffffffff;
static int captured_contents_responses = 0;

static UINT capture_file_contents_response(CliprdrClientContext *context,
										   const CLIPRDR_FILE_CONTENTS_RESPONSE *response)
{
	(void)context;
	captured_contents_responses++;
	captured_contents_flags = response->msgFlags;
	captured_contents_size = response->cbRequested;
	return 0;
}

/* The requested size is allocated before the file is read; it comes from the peer. */
static int test_file_contents_request_above_the_limit_is_refused(void)
{
	wfClipboard *clipboard = new_test_clipboard();
	CliprdrClientContext context;
	CLIPRDR_FILE_CONTENTS_REQUEST request;
	int failed = 0;

	if (!clipboard)
		return 1;
	ZeroMemory(&context, sizeof(context));
	context.Custom = clipboard;
	context.ClientFileContentsResponse = capture_file_contents_response;
	clipboard->context = &context;

	ZeroMemory(&request, sizeof(request));
	request.connID = 1;
	request.streamId = 5;
	request.dwFlags = FILECONTENTS_RANGE;
	request.cbRequested = WF_CLIPRDR_MAX_FILE_CONTENTS_REQUEST + 1u;
	captured_contents_responses = 0;
	failed += check_size("request above the limit is refused",
						 wf_cliprdr_server_file_contents_request(&context, &request),
						 ERROR_INVALID_PARAMETER);
	failed += check_size("request above the limit gets one response", (size_t)captured_contents_responses, 1);
	failed += check_size("request above the limit gets a failure response", captured_contents_flags,
						 CB_RESPONSE_FAIL);
	failed += check_size("request above the limit gets no data", captured_contents_size, 0);

	request.cbRequested = 0xffffffffu;
	failed += check_size("largest possible request is refused",
						 wf_cliprdr_server_file_contents_request(&context, &request),
						 ERROR_INVALID_PARAMETER);

	/* The size of a file is asked for with a fixed, small answer whatever the field says. */
	request.dwFlags = FILECONTENTS_SIZE;
	failed += check_bool("a size request is not refused for its size field",
						 wf_cliprdr_server_file_contents_request(&context, &request) != ERROR_INVALID_PARAMETER,
						 TRUE);

	free_test_clipboard(clipboard);
	return failed;
}

int main(void)
{
	int failed = 0;

	failed += test_descriptor_size_rejects_buffer_smaller_than_header();
	failed += test_descriptor_size_rejects_zero_items();
	failed += test_descriptor_size_accepts_max_stream_count();
	failed += test_descriptor_size_rejects_stream_count_above_limit();
	failed += test_descriptor_size_rejects_truncated_descriptor_array();
	failed += test_descriptor_size_rejects_extreme_count();
	failed += test_format_map_growth_zeroes_new_slots_and_is_bounded();
	failed += test_bounded_strlen_stops_at_the_limit();
	failed += test_format_list_rejects_oversized_lists_and_names();
	failed += test_file_contents_response_answers_only_the_outstanding_request();
	failed += test_format_data_request_is_answered_for_files_only();
	failed += test_file_contents_request_above_the_limit_is_refused();

	if (failed != 0) {
		fprintf(stderr, "wf_cliprdr invariant test failed: %d checks\n", failed);
		return EXIT_FAILURE;
	}

	printf("wf_cliprdr invariant test passed\n");
	return EXIT_SUCCESS;
}
