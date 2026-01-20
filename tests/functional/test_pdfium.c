/*
 * PDFium Functional Test Suite
 * Copyright (c) 2026 Qore Technologies, s.r.o.
 *
 * Comprehensive tests to verify the PDFium library works correctly
 * on all target platforms.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#include "fpdfview.h"
#include "fpdf_text.h"
#include "fpdf_edit.h"

/* Test result tracking */
static int tests_passed = 0;
static int tests_failed = 0;

#define TEST_ASSERT(cond, msg) do { \
    if (!(cond)) { \
        fprintf(stderr, "FAIL: %s\n", msg); \
        fprintf(stderr, "      at %s:%d\n", __FILE__, __LINE__); \
        tests_failed++; \
        return 0; \
    } \
    tests_passed++; \
} while(0)

#define TEST_ASSERT_MSG(cond, fmt, ...) do { \
    if (!(cond)) { \
        fprintf(stderr, "FAIL: " fmt "\n", ##__VA_ARGS__); \
        fprintf(stderr, "      at %s:%d\n", __FILE__, __LINE__); \
        tests_failed++; \
        return 0; \
    } \
    tests_passed++; \
} while(0)

/* Test: Library initialization */
static int test_library_init(void) {
    printf("  Testing library initialization...\n");

    /* Initialize the library */
    FPDF_LIBRARY_CONFIG config;
    memset(&config, 0, sizeof(config));
    config.version = 2;
    config.m_pUserFontPaths = NULL;
    config.m_pIsolate = NULL;
    config.m_v8EmbedderSlot = 0;

    FPDF_InitLibraryWithConfig(&config);

    /* If we get here without crashing, initialization worked */
    TEST_ASSERT(1, "Library initialized successfully");

    return 1;
}

/* Test: Document loading from file */
static int test_document_load(const char* pdf_path, FPDF_DOCUMENT* out_doc) {
    printf("  Testing document loading...\n");

    FPDF_DOCUMENT doc = FPDF_LoadDocument(pdf_path, NULL);
    TEST_ASSERT_MSG(doc != NULL, "Failed to load document: %s (error: %lu)",
                    pdf_path, FPDF_GetLastError());

    *out_doc = doc;
    return 1;
}

/* Test: Page count */
static int test_page_count(FPDF_DOCUMENT doc, int expected_count) {
    printf("  Testing page count...\n");

    int page_count = FPDF_GetPageCount(doc);
    TEST_ASSERT_MSG(page_count == expected_count,
                    "Expected %d pages, got %d", expected_count, page_count);

    return 1;
}

/* Test: Page loading and dimensions */
static int test_page_load(FPDF_DOCUMENT doc, int page_index, FPDF_PAGE* out_page) {
    printf("  Testing page %d loading...\n", page_index);

    FPDF_PAGE page = FPDF_LoadPage(doc, page_index);
    TEST_ASSERT_MSG(page != NULL, "Failed to load page %d", page_index);

    /* Test page dimensions (US Letter: 612x792 points) */
    double width = FPDF_GetPageWidth(page);
    double height = FPDF_GetPageHeight(page);

    TEST_ASSERT_MSG(width > 0, "Page width should be positive, got %f", width);
    TEST_ASSERT_MSG(height > 0, "Page height should be positive, got %f", height);

    /* Verify approximate US Letter size (allow some tolerance) */
    TEST_ASSERT_MSG(width > 600 && width < 620,
                    "Expected width ~612, got %f", width);
    TEST_ASSERT_MSG(height > 780 && height < 800,
                    "Expected height ~792, got %f", height);

    printf("    Page dimensions: %.1f x %.1f points\n", width, height);

    *out_page = page;
    return 1;
}

/* Test: Bitmap rendering */
static int test_render_page(FPDF_PAGE page, int page_index) {
    printf("  Testing page %d rendering...\n", page_index);

    /* Create a bitmap (100x100 pixels for quick test) */
    int width = 100;
    int height = 100;
    FPDF_BITMAP bitmap = FPDFBitmap_Create(width, height, 0);
    TEST_ASSERT(bitmap != NULL, "Failed to create bitmap");

    /* Fill with white background */
    FPDFBitmap_FillRect(bitmap, 0, 0, width, height, 0xFFFFFFFF);

    /* Render the page */
    FPDF_RenderPageBitmap(bitmap, page, 0, 0, width, height, 0, 0);

    /* Get bitmap buffer and verify it's not all white (something was rendered) */
    void* buffer = FPDFBitmap_GetBuffer(bitmap);
    TEST_ASSERT(buffer != NULL, "Failed to get bitmap buffer");

    int stride = FPDFBitmap_GetStride(bitmap);
    TEST_ASSERT_MSG(stride > 0, "Invalid bitmap stride: %d", stride);

    /* Check that rendering produced some non-white pixels */
    uint8_t* pixels = (uint8_t*)buffer;
    int non_white_count = 0;
    for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
            int offset = y * stride + x * 4;
            /* BGRA format - check if not white (0xFFFFFFFF) */
            if (pixels[offset] != 0xFF || pixels[offset+1] != 0xFF ||
                pixels[offset+2] != 0xFF) {
                non_white_count++;
            }
        }
    }

    printf("    Rendered %d non-white pixels\n", non_white_count);
    TEST_ASSERT_MSG(non_white_count > 0,
                    "Rendering produced no visible content (all white)");

    FPDFBitmap_Destroy(bitmap);
    return 1;
}

/* Test: Text extraction */
static int test_text_extraction(FPDF_PAGE page, int page_index, const char* expected_substr) {
    printf("  Testing text extraction from page %d...\n", page_index);

    FPDF_TEXTPAGE text_page = FPDFText_LoadPage(page);
    TEST_ASSERT(text_page != NULL, "Failed to load text page");

    int char_count = FPDFText_CountChars(text_page);
    TEST_ASSERT_MSG(char_count > 0, "No text found on page %d", page_index);
    printf("    Found %d characters\n", char_count);

    /* Extract text (allocate buffer for chars + null terminator) */
    int buffer_len = char_count + 1;
    unsigned short* text_buffer = (unsigned short*)malloc(buffer_len * sizeof(unsigned short));
    TEST_ASSERT(text_buffer != NULL, "Failed to allocate text buffer");

    int extracted = FPDFText_GetText(text_page, 0, char_count, text_buffer);
    TEST_ASSERT_MSG(extracted > 0, "Failed to extract text from page %d", page_index);

    /* Convert UTF-16 to ASCII for simple comparison */
    char* ascii_text = (char*)malloc(extracted + 1);
    for (int i = 0; i < extracted; i++) {
        ascii_text[i] = (char)(text_buffer[i] & 0xFF);
    }
    ascii_text[extracted] = '\0';

    printf("    Extracted text: \"%s\"\n", ascii_text);

    /* Check if expected substring is present */
    TEST_ASSERT_MSG(strstr(ascii_text, expected_substr) != NULL,
                    "Expected text containing \"%s\", got \"%s\"",
                    expected_substr, ascii_text);

    free(ascii_text);
    free(text_buffer);
    FPDFText_ClosePage(text_page);
    return 1;
}

/* Test: Large bitmap rendering (stress test) */
static int test_large_render(FPDF_PAGE page) {
    printf("  Testing large bitmap rendering (1000x1000)...\n");

    int width = 1000;
    int height = 1000;
    FPDF_BITMAP bitmap = FPDFBitmap_Create(width, height, 0);
    TEST_ASSERT(bitmap != NULL, "Failed to create large bitmap");

    FPDFBitmap_FillRect(bitmap, 0, 0, width, height, 0xFFFFFFFF);
    FPDF_RenderPageBitmap(bitmap, page, 0, 0, width, height, 0, 0);

    void* buffer = FPDFBitmap_GetBuffer(bitmap);
    TEST_ASSERT(buffer != NULL, "Failed to get large bitmap buffer");

    /* Verify buffer size makes sense */
    int stride = FPDFBitmap_GetStride(bitmap);
    TEST_ASSERT_MSG(stride >= width * 4,
                    "Stride too small: %d (expected >= %d)", stride, width * 4);

    printf("    Large render successful (stride: %d)\n", stride);

    FPDFBitmap_Destroy(bitmap);
    return 1;
}

/* Test: Document memory loading */
static int test_memory_load(const char* pdf_path) {
    printf("  Testing document loading from memory...\n");

    /* Read file into memory */
    FILE* f = fopen(pdf_path, "rb");
    TEST_ASSERT_MSG(f != NULL, "Failed to open file: %s", pdf_path);

    fseek(f, 0, SEEK_END);
    long file_size = ftell(f);
    fseek(f, 0, SEEK_SET);

    TEST_ASSERT_MSG(file_size > 0, "File is empty: %s", pdf_path);

    void* buffer = malloc(file_size);
    TEST_ASSERT(buffer != NULL, "Failed to allocate file buffer");

    size_t read_size = fread(buffer, 1, file_size, f);
    fclose(f);
    TEST_ASSERT_MSG(read_size == (size_t)file_size,
                    "Failed to read entire file (read %zu of %ld)",
                    read_size, file_size);

    /* Load from memory */
    FPDF_DOCUMENT doc = FPDF_LoadMemDocument(buffer, file_size, NULL);
    TEST_ASSERT(doc != NULL, "Failed to load document from memory");

    int page_count = FPDF_GetPageCount(doc);
    TEST_ASSERT_MSG(page_count > 0, "Memory-loaded doc has no pages");

    printf("    Memory load successful (%ld bytes, %d pages)\n",
           file_size, page_count);

    FPDF_CloseDocument(doc);
    free(buffer);
    return 1;
}

/* Test: Error handling for invalid file */
static int test_error_handling(void) {
    printf("  Testing error handling...\n");

    /* Try to load non-existent file */
    FPDF_DOCUMENT doc = FPDF_LoadDocument("/nonexistent/path/to/file.pdf", NULL);
    TEST_ASSERT(doc == NULL, "Should fail to load non-existent file");

    unsigned long error = FPDF_GetLastError();
    TEST_ASSERT_MSG(error != 0, "Expected error code, got 0");
    printf("    Correctly returned error code: %lu\n", error);

    /* Try to load invalid PDF data */
    const char* invalid_data = "This is not a PDF file";
    doc = FPDF_LoadMemDocument(invalid_data, strlen(invalid_data), NULL);
    TEST_ASSERT(doc == NULL, "Should fail to load invalid PDF data");

    error = FPDF_GetLastError();
    TEST_ASSERT_MSG(error != 0, "Expected error code for invalid data, got 0");
    printf("    Correctly rejected invalid PDF data (error: %lu)\n", error);

    return 1;
}

/* Test: Multiple document handling */
static int test_multiple_documents(const char* pdf_path) {
    printf("  Testing multiple simultaneous documents...\n");

    FPDF_DOCUMENT docs[3];

    /* Open same document multiple times */
    for (int i = 0; i < 3; i++) {
        docs[i] = FPDF_LoadDocument(pdf_path, NULL);
        TEST_ASSERT_MSG(docs[i] != NULL, "Failed to open document %d", i);
    }

    /* Verify each has correct page count */
    for (int i = 0; i < 3; i++) {
        int count = FPDF_GetPageCount(docs[i]);
        TEST_ASSERT_MSG(count == 2, "Doc %d: expected 2 pages, got %d", i, count);
    }

    /* Close in reverse order */
    for (int i = 2; i >= 0; i--) {
        FPDF_CloseDocument(docs[i]);
    }

    printf("    Multiple document handling successful\n");
    return 1;
}

/* Main test runner */
int main(int argc, char* argv[]) {
    if (argc < 2) {
        fprintf(stderr, "Usage: %s <path-to-test.pdf>\n", argv[0]);
        return 1;
    }

    const char* pdf_path = argv[1];
    printf("PDFium Functional Test Suite\n");
    printf("=============================\n");
    printf("Test PDF: %s\n\n", pdf_path);

    /* Initialize library */
    printf("Test 1: Library Initialization\n");
    if (!test_library_init()) {
        fprintf(stderr, "FATAL: Library initialization failed, cannot continue\n");
        return 1;
    }

    /* Load document */
    printf("\nTest 2: Document Loading\n");
    FPDF_DOCUMENT doc = NULL;
    if (!test_document_load(pdf_path, &doc)) {
        FPDF_DestroyLibrary();
        return 1;
    }

    /* Page count */
    printf("\nTest 3: Page Count\n");
    test_page_count(doc, 2);

    /* Load and test page 1 */
    printf("\nTest 4: Page 1 Loading and Dimensions\n");
    FPDF_PAGE page1 = NULL;
    if (test_page_load(doc, 0, &page1)) {
        printf("\nTest 5: Page 1 Rendering\n");
        test_render_page(page1, 0);

        printf("\nTest 6: Page 1 Text Extraction\n");
        test_text_extraction(page1, 0, "Hello");

        printf("\nTest 7: Large Bitmap Rendering\n");
        test_large_render(page1);

        FPDF_ClosePage(page1);
    }

    /* Load and test page 2 */
    printf("\nTest 8: Page 2 Loading and Dimensions\n");
    FPDF_PAGE page2 = NULL;
    if (test_page_load(doc, 1, &page2)) {
        printf("\nTest 9: Page 2 Rendering\n");
        test_render_page(page2, 1);

        printf("\nTest 10: Page 2 Text Extraction\n");
        test_text_extraction(page2, 1, "Page");

        FPDF_ClosePage(page2);
    }

    FPDF_CloseDocument(doc);

    /* Additional tests */
    printf("\nTest 11: Memory Document Loading\n");
    test_memory_load(pdf_path);

    printf("\nTest 12: Error Handling\n");
    test_error_handling();

    printf("\nTest 13: Multiple Document Handling\n");
    test_multiple_documents(pdf_path);

    /* Cleanup */
    FPDF_DestroyLibrary();

    /* Print summary */
    printf("\n=============================\n");
    printf("Test Summary\n");
    printf("=============================\n");
    printf("Passed: %d\n", tests_passed);
    printf("Failed: %d\n", tests_failed);

    if (tests_failed > 0) {
        printf("\nRESULT: FAILED\n");
        return 1;
    }

    printf("\nRESULT: PASSED\n");
    return 0;
}
