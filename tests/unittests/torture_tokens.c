/*
 * torture_tokens.c - Tests for tokens list handling
 *
 * This file is part of the SSH Library
 *
 * Copyright (c) 2019 by Red Hat, Inc.
 *
 * Author: Anderson Toshiyuki Sasaki <ansasaki@redhat.com>
 *
 * The SSH Library is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation; either version 2.1 of the License, or (at your
 * option) any later version.
 *
 * The SSH Library is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
 * or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU Lesser General Public
 * License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with the SSH Library; see the file COPYING.  If not, write to
 * the Free Software Foundation, Inc., 59 Temple Place - Suite 330, Boston,
 * MA 02111-1307, USA.
 */

#include "config.h"

#define LIBSSH_STATIC

#include "torture.h"
#include "libssh/token.h"
#include "libssh/priv.h"

static void torture_find_matching(UNUSED_PARAM(void **state))
{
    char *matching;

    /* Match with single token */
    matching = ssh_find_matching("a,b,c", "b");
    assert_non_null(matching);
    assert_string_equal(matching, "b");
    SAFE_FREE(matching);

    /* Match sequence, get first preferred */
    matching = ssh_find_matching("a,b,c", "b,c");
    assert_non_null(matching);
    assert_string_equal(matching, "b");
    SAFE_FREE(matching);

    /* Only one token allowed */
    matching = ssh_find_matching("c", "a,b,c");
    assert_non_null(matching);
    assert_string_equal(matching, "c");
    SAFE_FREE(matching);

    /* Different order in allowed and preferred; gets preferred */
    matching = ssh_find_matching("c,b,a", "a,b,c");
    assert_non_null(matching);
    assert_string_equal(matching, "a");
    SAFE_FREE(matching);

    /* No matching returns NULL */
    matching = ssh_find_matching("c,b,a", "d,e,f");
    assert_null(matching);
}

static void torture_find_all_matching(UNUSED_PARAM(void **state))
{
    char *matching;

    /* Match with single token */
    matching = ssh_find_all_matching("a,b,c", "b");
    assert_non_null(matching);
    assert_string_equal(matching, "b");
    SAFE_FREE(matching);

    /* Match sequence, get first preferred */
    matching = ssh_find_all_matching("a,b,c", "b,c");
    assert_non_null(matching);
    assert_string_equal(matching, "b,c");
    SAFE_FREE(matching);

    /* Only one token allowed */
    matching = ssh_find_all_matching("c", "a,b,c");
    assert_non_null(matching);
    assert_string_equal(matching, "c");
    SAFE_FREE(matching);

    /* Different order in allowed and preferred; gets preferred */
    matching = ssh_find_all_matching("c,b,a", "a,c,b");
    assert_non_null(matching);
    assert_string_equal(matching, "a,c,b");
    SAFE_FREE(matching);

    /* No matching returns NULL */
    matching = ssh_find_all_matching("c,b,a", "d,e,f");
    assert_null(matching);
}

static void tokenize_compare_expected(const char *chain, const char **expected,
                                     size_t num_expected)
{
    struct ssh_tokens_st *tokens;
    size_t i;

    tokens = ssh_tokenize(chain, ',');
    assert_non_null(tokens);

    if (expected != NULL) {
        assert_non_null(tokens->tokens);
        for (i = 0; i < num_expected; i++) {
            assert_non_null(tokens->tokens[i]);
            assert_non_null(expected[i]);
            assert_string_equal(tokens->tokens[i], expected[i]);
        }

        assert_null(tokens->tokens[i]);

        i = 0;
        printf("Tokenizing \"%s\" resulted in: ", chain);
        while (tokens->tokens[i]) {
            printf("\"%s\" ", tokens->tokens[i++]);
        }
        printf("\n");
    }

    ssh_tokens_free(tokens);
}

static void torture_tokens_sanity(UNUSED_PARAM(void **state))
{
    const char *simple[] = {"a", "b", "c"};
    const char *colon_first[] = {"", "a", "b", "c"};
    const char *colon_end[] = {"a", "b", "c"};
    const char *colon_both[] = {"", "a", "b", "c"};
    const char *single[] = {"abc"};
    const char *empty[] = {""};
    const char *single_colon[] = {""};

    tokenize_compare_expected("a,b,c", simple, 3);
    tokenize_compare_expected(",a,b,c", colon_first, 4);
    tokenize_compare_expected("a,b,c,", colon_end, 3);
    tokenize_compare_expected(",a,b,c,", colon_both, 4);
    tokenize_compare_expected("abc", single, 1);
    tokenize_compare_expected("", empty, 1);
    tokenize_compare_expected(",", single_colon, 1);
}

int torture_run_tests(void)
{
    int rc;
    struct CMUnitTest tests[] = {
        cmocka_unit_test(torture_tokens_sanity),
        cmocka_unit_test(torture_find_matching),
        cmocka_unit_test(torture_find_all_matching),
    };

    ssh_init();
    torture_filter_tests(tests);
    rc = cmocka_run_group_tests(tests, NULL, NULL);
    ssh_finalize();
    return rc;
}
