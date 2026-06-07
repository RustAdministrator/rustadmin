#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>

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

int main(void)
{
	int failed = 0;

	failed += test_descriptor_size_rejects_buffer_smaller_than_header();
	failed += test_descriptor_size_rejects_zero_items();
	failed += test_descriptor_size_accepts_max_stream_count();
	failed += test_descriptor_size_rejects_stream_count_above_limit();
	failed += test_descriptor_size_rejects_truncated_descriptor_array();
	failed += test_descriptor_size_rejects_extreme_count();

	if (failed != 0) {
		fprintf(stderr, "wf_cliprdr invariant test failed: %d checks\n", failed);
		return EXIT_FAILURE;
	}

	printf("wf_cliprdr invariant test passed\n");
	return EXIT_SUCCESS;
}
