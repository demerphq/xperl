/*    run.c
 *
 *    Copyright (C) 1991, 1992, 1993, 1994, 1995, 1996, 1997, 1998, 1999,
 *    2000, 2001, 2004, 2005, 2006, by Larry Wall and others
 *
 *    You may distribute under the terms of either the GNU General Public
 *    License or the Artistic License, as specified in the README file.
 *
 */

/* This file contains the main Perl opcode execution loop. It just
 * calls the pp_foo() function associated with each op, and expects that
 * function to return a pointer to the next op to be executed, or null if
 * it's the end of the sub or program or whatever.
 *
 * There is a similar loop in dump.c, Perl_runops_debug(), which does
 * the same, but also checks for various debug flags each time round the
 * loop.
 *
 * Why this function requires a file all of its own is anybody's guess.
 * DAPM.
 */

#include "EXTERN.h"
#define PERL_IN_RUN_C
#include "perl.h"
#include "XSUB.h"
#include "regcomp.h"
#include "diagpack.h"

/*
 * 'Away now, Shadowfax!  Run, greatheart, run as you have never run before!
 *  Now we are come to the lands where you were foaled, and every stone you
 *  know.  Run now!  Hope is in speed!'                    --Gandalf
 *
 *     [p.600 of _The Lord of the Rings_, III/xi: "The Palantír"]
 */

static XS(XS_generator_exhausted);
static XS(XS_generator_completed);
static XS(XS_generator_failed);
static XS(XS_generator_running);
static XS(XS_generator_clone_skip);
static XS(XS_iterator_new);
static XS(XS_iterator_state);
static XS(XS_iterator_set_state);
static XS(XS_iterator_exhausted);
static XS(XS_iterator_completed);
static XS(XS_iterator_failed);
static XS(XS_iterator_running);
static int S_runops_with_boundary(pTHX);
static int S_runops_with_hook(pTHX_ runops_boundary_proc_t hook, void *data);
static XS(S_generator_xsub);
static XS(S_async_factory);
static XS(S_async_step);
static XS(S_async_close);
static XS(S_async_claim);

static MGVTBL S_iter_adapter_magic = { 0, 0, 0, 0, 0, 0, 0, 0 };

/* $1 and friends belong to a regexp, not just to PL_curpm. Two suspended
 * calls can use the same match opcode and overwrite each other's results.
 * We move each live result into its execution's saved state at a switch,
 * then put it back before that execution runs again. The compiled pattern
 * stays shared. Ordinary matches and subroutine calls need no new checks.
 *
 * Keep the actual regexp and its complete offsets. Replacing it with a
 * frozen copy would change how repeated matches through the same opcode
 * affect captures within one execution. Dynamic patterns need their opcode
 * binding restored too. Several opcodes can share one regexp, so the result
 * has one owner even when several saved bindings refer to it.
 */
typedef struct execution_match {
    PMOP *pm;
    REGEXP *rx;
    regexp_paren_pair *offsets;
    char *subject;
#ifdef PERL_ANY_COW
    SV *saved_copy;
#endif
    SSize_t length, byte_offset, char_offset;
    U32 flags, lastparen, lastcloseparen;
    bool owns_result;
    struct execution_match *next;
} EXECUTION_MATCH;

typedef struct execution_matches {
    EXECUTION_MATCH *head;
    bool parked;
    bool restore_on_free;
} EXECUTION_MATCHES;

#define EXECUTION_MATCH_FLAGS (RXf_COPY_DONE | RXf_MATCH_UTF8 | RXf_TAINTED_SEEN)

static void S_execution_matches_restore(pTHX_ SV *holder);

static int
S_execution_matches_free(pTHX_ SV *sv, MAGIC *mg)
{
    EXECUTION_MATCHES * const matches = (EXECUTION_MATCHES *)mg->mg_ptr;
    EXECUTION_MATCH *entry;
    if (!matches)
        return 0;
    if (matches->restore_on_free && matches->parked)
        S_execution_matches_restore(aTHX_ sv);
    mg->mg_ptr = NULL;
    entry = matches->head;
    while (entry) {
        EXECUTION_MATCH * const next = entry->next;
        if (matches->parked && entry->owns_result) {
            if (entry->flags & RXf_COPY_DONE)
                Safefree(entry->subject);
#ifdef PERL_ANY_COW
            SvREFCNT_dec(entry->saved_copy);
#endif
        }
        Safefree(entry->offsets);
        SvREFCNT_dec(MUTABLE_SV(entry->rx));
        Safefree(entry);
        entry = next;
    }
    Safefree(matches);
    return 0;
}

#ifdef USE_ITHREADS
static int
S_execution_matches_dup(pTHX_ MAGIC *mg, CLONE_PARAMS *param)
{
    PERL_UNUSED_CONTEXT;
    PERL_UNUSED_ARG(param);
    /* The child has its own regexps and cannot own this native guard. */
    mg->mg_ptr = NULL;
    return 0;
}
#endif

static MGVTBL S_execution_matches_magic = {
    0, 0, 0, 0, S_execution_matches_free, 0,
#ifdef USE_ITHREADS
    S_execution_matches_dup,
#else
    0,
#endif
    0
};

/* Preparation can fail without changing any match. Moving and restoring
 * results happen only after every allocation and eligibility check. */
static void
S_execution_match_root(pTHX_ AV **roots, void *pointer)
{
    if (!pointer)
        return;
    if (!*roots)
        *roots = (AV *)sv_2mortal(MUTABLE_SV(newAV()));
    av_push(*roots, newSVuv(PTR2UV(pointer)));
}

static SV *
S_execution_matches_prepare(pTHX_ bool caller)
{
    SV *holder;
    AV *roots = NULL, *rx_roots = NULL;
    HV *seen_pm, *seen_rx;
    EXECUTION_MATCHES *matches;
    MAGIC *mg;
    SSize_t i;
    PERL_SI *si;
    if (!caller && PL_curpm && PL_curpm == PL_reg_curpm)
        PERL_THROW_ERROR_ITERATOR_GENERATOR_MATCH_UNSUPPORTED();
    S_execution_match_root(aTHX_ &roots, PL_curpm);
    for (si = PL_curstackinfo; si; si = si->si_prev) {
        for (i = 0; i <= si->si_cxix; ++i) {
            PERL_CONTEXT * const cx = &si->si_cxstack[i];
            if (CxTYPE(cx) == CXt_SUBST) {
                if (!caller)
                    PERL_THROW_ERROR_ITERATOR_GENERATOR_MATCH_UNSUPPORTED();
                S_execution_match_root(aTHX_ &rx_roots, cx->sb_rx);
                continue;
            }
            S_execution_match_root(aTHX_ &roots, cx->blk_oldpm);
        }
        if (si->si_type == PERLSI_GENERATOR)
            break;
    }
    roots = execution_match_roots(roots);
    /* curpm_under may be stale after (?{}) finishes. Read it only when the
     * saved roots include the engine's active match. */
    if (caller && roots) {
        for (i = 0; i <= AvFILLp(roots); ++i) {
            if (INT2PTR(PMOP *, SvUV(AvARRAY(roots)[i])) == PL_reg_curpm) {
                S_execution_match_root(aTHX_ &roots, PL_curpm_under);
                break;
            }
        }
    }
    if (!roots && !rx_roots)
        return NULL;
    holder = sv_newmortal();
    seen_pm = (HV *)sv_2mortal(MUTABLE_SV(newHV()));
    seen_rx = (HV *)sv_2mortal(MUTABLE_SV(newHV()));
    Newxz(matches, 1, EXECUTION_MATCHES);
    matches->restore_on_free = caller;
    mg = sv_magicext(holder, NULL, PERL_MAGIC_ext, &S_execution_matches_magic,
                     (char *)matches, 0);
    mg->mg_flags |= MGf_DUP;
    const SSize_t pm_count = roots ? AvFILLp(roots) + 1 : 0;
    const SSize_t rx_count = rx_roots ? AvFILLp(rx_roots) + 1 : 0;
    for (i = 0; i < pm_count + rx_count; ++i) {
        PMOP * const pm = i < pm_count
            ? INT2PTR(PMOP *, SvUV(AvARRAY(roots)[i])) : NULL;
        REGEXP *rx;
        EXECUTION_MATCH *entry;
        if (i < pm_count) {
            if (!pm || hv_exists(seen_pm, (char *)&pm, sizeof(pm)))
                continue;
            (void)hv_store(seen_pm, (char *)&pm, sizeof(pm), newSViv(1), 0);
            rx = PM_GETRE(pm);
        }
        else
            rx = INT2PTR(REGEXP *, SvUV(AvARRAY(rx_roots)[i - pm_count]));
        if (!rx)
            continue;
        if (!caller && (pm == PL_reg_curpm
            || RX_ENGINE(rx) != &PL_core_reg_engine
            || sv_has_valuemagic(MUTABLE_SV(rx))
            || (RX_SUBBEG(rx) && !RX_MATCH_COPIED(rx)
#ifdef PERL_ANY_COW
                && !RX_SAVED_COPY(rx)
#endif
                )))
            PERL_THROW_ERROR_ITERATOR_GENERATOR_MATCH_UNSUPPORTED();
        Newxz(entry, 1, EXECUTION_MATCH);
        entry->pm = pm;
        entry->rx = (REGEXP *)SvREFCNT_inc_simple_NN(rx);
        entry->next = matches->head;
        matches->head = entry;
        /* Save a native caller's borrowed pointer without reading its bytes.
         * The caller resumes before its native frame returns. Cleanup must
         * not reject this caller. Custom engines retain ordinary callback
         * semantics: we protect their binding, not private engine state. */
        if (RX_ENGINE(rx) == &PL_core_reg_engine
            && !hv_exists(seen_rx, (char *)&rx, sizeof(rx))) {
            (void)hv_store(seen_rx, (char *)&rx, sizeof(rx), newSViv(1), 0);
            entry->owns_result = TRUE;
            if (RX_OFFSp(rx))
                NewCopy(RX_OFFSp(rx), entry->offsets, RX_NPARENS(rx) + 1,
                        regexp_paren_pair);
        }
    }
    return holder;
}

static void
S_execution_matches_park(pTHX_ SV *holder)
{
    if (!holder)
        return;
    EXECUTION_MATCHES * const matches = (EXECUTION_MATCHES *)
        mg_findext(holder, PERL_MAGIC_ext, &S_execution_matches_magic)->mg_ptr;
    EXECUTION_MATCH *entry;
    PERL_UNUSED_CONTEXT;
    assert(!matches->parked);
    for (entry = matches->head; entry; entry = entry->next) {
        REGEXP * const rx = entry->rx;
        if (!entry->owns_result)
            continue;
        entry->subject = RX_SUBBEG(rx);
#ifdef PERL_ANY_COW
        entry->saved_copy = RX_SAVED_COPY(rx);
        RX_SAVED_COPY(rx) = NULL;
#endif
        entry->length = RX_SUBLEN(rx);
        entry->byte_offset = RX_SUBOFFSET(rx);
        entry->char_offset = RX_SUBCOFFSET(rx);
        entry->lastparen = RX_LASTPAREN(rx);
        entry->lastcloseparen = RX_LASTCLOSEPAREN(rx);
        entry->flags = RX_EXTFLAGS(rx) & EXECUTION_MATCH_FLAGS;
        RX_EXTFLAGS(rx) &= ~EXECUTION_MATCH_FLAGS;
        RX_SUBBEG(rx) = NULL;
        RX_SUBLEN(rx) = RX_SUBOFFSET(rx) = RX_SUBCOFFSET(rx) = 0;
        RX_LASTPAREN(rx) = RX_LASTCLOSEPAREN(rx) = 0;
        if (RX_OFFSp(rx)) {
            U32 i;
            for (i = 0; i <= RX_NPARENS(rx); ++i)
                RX_OFFSp(rx)[i].start = RX_OFFSp(rx)[i].end
                    = RX_OFFSp(rx)[i].start_tmp = -1;
        }
    }
    matches->parked = TRUE;
}

static void
S_execution_matches_restore(pTHX_ SV *holder)
{
    if (!holder)
        return;
    EXECUTION_MATCHES * const matches = (EXECUTION_MATCHES *)
        mg_findext(holder, PERL_MAGIC_ext, &S_execution_matches_magic)->mg_ptr;
    EXECUTION_MATCH *entry;
    SSize_t count = 0;
    if (!matches || !matches->parked)
        return;
    for (entry = matches->head; entry; entry = entry->next)
        ++count;
    EXTEND_MORTAL(count);
    /* Defer releasing displaced regexps. Their embedded code can have
     * destructors, and those must see a fully restored execution. */
    for (entry = matches->head; entry; entry = entry->next) {
        if (!entry->pm)
            continue;
        REGEXP * const old = PM_GETRE(entry->pm);
        if (old != entry->rx) {
            PM_SETRE(entry->pm, (REGEXP *)SvREFCNT_inc_simple_NN(entry->rx));
            if (old)
                sv_2mortal(MUTABLE_SV(old));
        }
    }
    for (entry = matches->head; entry; entry = entry->next) {
        REGEXP * const rx = entry->rx;
        if (!entry->owns_result)
            continue;
        RX_MATCH_COPY_FREE(rx);
#ifdef PERL_ANY_COW
        SvREFCNT_dec(RX_SAVED_COPY(rx));
        RX_SAVED_COPY(rx) = entry->saved_copy;
        entry->saved_copy = NULL;
#endif
        RX_SUBBEG(rx) = entry->subject;
        entry->subject = NULL;
        RX_SUBLEN(rx) = entry->length;
        RX_SUBOFFSET(rx) = entry->byte_offset;
        RX_SUBCOFFSET(rx) = entry->char_offset;
        RX_LASTPAREN(rx) = entry->lastparen;
        RX_LASTCLOSEPAREN(rx) = entry->lastcloseparen;
        RX_EXTFLAGS(rx) = (RX_EXTFLAGS(rx) & ~EXECUTION_MATCH_FLAGS) | entry->flags;
        if (entry->offsets)
            Copy(entry->offsets, RX_OFFSp(rx), RX_NPARENS(rx) + 1,
                 regexp_paren_pair);
    }
    matches->parked = FALSE;
}

/* A suspended Perl call keeps its live pad AVs, not copies of their values.
 * Otherwise returning from one generator can lower the shared CvDEPTH and
 * let a new call overwrite another generator's lexicals and arguments.
 *
 * On the first suspension we move each live activation's pad into a private
 * padlist and give the CV spare frames made by the normal recursion rules.
 * Caller frames below this execution boundary stay in the outside padlist.
 * Resuming installs the private padlist and depth. Suspending restores the
 * padlist and depth displaced by that particular resume, since the current
 * caller may differ from the caller which first started the generator.
 *
 * Normal subroutine calls use the installed padlist without extra checks.
 * The bookkeeping belongs here at execution boundaries. The CV's magic lets
 * string eval find a parked activation and prevents undefining its body.
 */
typedef struct perl_suspended_pad {
    CV *cv;
    PADLIST *private_padlist;
    PADLIST *outside_padlist;
    I32 private_depth;
    I32 outside_depth;
    bool installed;
    bool live;
    struct perl_suspended_pad *next;
    struct perl_suspended_pad *cv_next;
    struct perl_suspended_pad **cv_prev;
} SUSPENDED_PAD;

static int
S_suspended_cv_free(pTHX_ SV *sv, MAGIC *mg)
{
    PERL_UNUSED_CONTEXT;
    PERL_UNUSED_ARG(sv);
    Safefree(mg->mg_ptr);
    mg->mg_ptr = NULL;
    return 0;
}

#ifdef USE_ITHREADS
static int
S_suspended_cv_dup(pTHX_ MAGIC *mg, CLONE_PARAMS *param)
{
    SUSPENDED_PAD **head;
    PERL_UNUSED_CONTEXT;
    PERL_UNUSED_ARG(param);
    Newxz(head, 1, SUSPENDED_PAD *);
    /* Generator continuations are not cloned into the child interpreter. */
    mg->mg_ptr = (char *)head;
    return 0;
}
#endif

static MGVTBL S_suspended_cv_magic = {
    0, 0, 0, 0, S_suspended_cv_free, 0,
#ifdef USE_ITHREADS
    S_suspended_cv_dup,
#else
    0,
#endif
    0
};

static SUSPENDED_PAD **
S_suspended_cv_pads(pTHX_ CV *cv, bool create)
{
    MAGIC *mg = mg_findext(MUTABLE_SV(cv), PERL_MAGIC_ext, &S_suspended_cv_magic);
    if (!mg && create) {
        SUSPENDED_PAD **head;
        Newxz(head, 1, SUSPENDED_PAD *);
        mg = sv_magicext(MUTABLE_SV(cv), NULL, PERL_MAGIC_ext,
                         &S_suspended_cv_magic, (char *)head, 0);
        mg->mg_flags |= MGf_DUP;
    }
    return mg ? (SUSPENDED_PAD **)mg->mg_ptr : NULL;
}

bool
Perl_pad_in_suspended_execution(pTHX_ CV *cv)
{
    SUSPENDED_PAD **head;
    PERL_ARGS_ASSERT_PAD_IN_SUSPENDED_EXECUTION;
    head = S_suspended_cv_pads(aTHX_ cv, FALSE);
    return head && *head;
}

/* String eval follows CvOUTSIDE dynamically. With no running activation,
 * it must find the most recently parked activation rather than a spare pad.
 * Ordinary active calls retain their usual depth-based lookup. */
PAD *
Perl_pad_find_suspended_frame(pTHX_ const CV *cv)
{
    SUSPENDED_PAD **head;
    SUSPENDED_PAD *pad;
    PERL_ARGS_ASSERT_PAD_FIND_SUSPENDED_FRAME;
    head = S_suspended_cv_pads(aTHX_ (CV *)cv, FALSE);
    for (pad = head ? *head : NULL; pad; pad = pad->cv_next) {
        if (pad->live && !pad->installed)
            return PadlistARRAY(pad->private_padlist)[pad->private_depth];
    }
    return NULL;
}

static void
S_suspended_pad_unlink(pTHX_ SUSPENDED_PAD *pad)
{
    PERL_UNUSED_CONTEXT;
    assert(pad->cv_prev && *pad->cv_prev == pad);
    *pad->cv_prev = pad->cv_next;
    if (pad->cv_next)
        pad->cv_next->cv_prev = pad->cv_prev;
    pad->cv_next = NULL;
    pad->cv_prev = NULL;
}

static void
S_suspended_pad_link(pTHX_ SUSPENDED_PAD *pad)
{
    SUSPENDED_PAD **head = S_suspended_cv_pads(aTHX_ pad->cv, TRUE);
    assert(!pad->cv_prev);
    pad->cv_next = *head;
    pad->cv_prev = head;
    if (*head)
        (*head)->cv_prev = &pad->cv_next;
    *head = pad;
}

static void
S_suspended_pad_restore(pTHX_ SUSPENDED_PAD *pad)
{
    PERL_UNUSED_CONTEXT;
    if (!pad->installed)
        return;
    pad->private_padlist = CvPADLIST(pad->cv);
    pad->private_depth = CvDEPTH(pad->cv);
    CvPADLIST_set(pad->cv, pad->outside_padlist);
    CvDEPTH(pad->cv) = pad->outside_depth;
    pad->outside_padlist = NULL;
    pad->installed = FALSE;
}

static void
S_generator_restore_pads(pTHX_ PERL_GENERATOR *generator)
{
    SUSPENDED_PAD *pad;
    for (pad = generator->pads; pad; pad = pad->next)
        S_suspended_pad_restore(aTHX_ pad);
}

static void
S_generator_install_pads(pTHX_ PERL_GENERATOR *generator)
{
    SUSPENDED_PAD *pad;
    for (pad = generator->pads; pad; pad = pad->next) {
        assert(!pad->installed);
        pad->outside_padlist = CvPADLIST(pad->cv);
        pad->outside_depth = CvDEPTH(pad->cv);
        CvPADLIST_set(pad->cv, pad->private_padlist);
        CvDEPTH(pad->cv) = pad->private_depth;
        pad->installed = TRUE;
    }
}

static void
S_suspended_pad_free(pTHX_ SUSPENDED_PAD *pad)
{
    PADLIST *list = pad->private_padlist;
    PADNAMELIST *names = PadlistNAMES(list);
    AV *garbage = newAV();
    const bool destroying = PL_phase == PERL_PHASE_DESTRUCT;
    const I32 oldsave = PL_savestack_ix;
    SSize_t i;
    assert(!pad->installed);
    S_suspended_pad_unlink(aTHX_ pad);

    /* Release the temporary owner here, even if this is the last boundary
     * before global destruction. Its exception guard belongs to this scope,
     * rather than a private mortal stack which may never run again. */
    if (!destroying) {
        SAVEFREESV(garbage);
    }

    /* The AV owns everything before any destructor runs. Its reverse
     * cleanup order releases the pads before the CV itself. */
    av_push(garbage, MUTABLE_SV(pad->cv));
    for (i = 1; i <= PadlistMAX(list); ++i) {
        PAD *frame = PadlistARRAY(list)[i];
        SSize_t j;
        if (!frame)
            continue;
        /* Escaped lexical subs need their outside CV after this private
         * pad disappears. The CV's ordinary padlist cannot find them when
         * it later clears its weak outside links. */
        for (j = 1; j <= AvFILLp(frame) && j <= PadnamelistMAX(names); ++j) {
            PADNAME *name = PadnamelistARRAY(names)[j];
            SV *sv = AvARRAY(frame)[j];
            if (name && PadnameLEN(name) && PadnamePV(name)[0] == '&'
                && !PadnameOUTER(name) && !PadnameIsSTATE(name)
                && sv && SvTYPE(sv) == SVt_PVCV && SvREFCNT(sv) > 1
                && CvLEXICAL((CV *)sv) && CvCLONED((CV *)sv)
                && CvWEAKOUTSIDE((CV *)sv) && CvOUTSIDE((CV *)sv) == pad->cv) {
                CvWEAKOUTSIDE_off((CV *)sv);
                SvREFCNT_inc_simple_void_NN(pad->cv);
            }
        }
        av_push(garbage, MUTABLE_SV(frame));
    }
    PadnamelistREFCNT_dec(names);
    Safefree(PadlistARRAY(list));
    Safefree(list);
    Safefree(pad);
    if (destroying)
        SvREFCNT_dec_NN(garbage);
    else {
        av_clear(garbage);
        LEAVE_SCOPE(oldsave);
    }
}

static void
S_generator_free_pads(pTHX_ PERL_GENERATOR *generator)
{
    while (generator->pads) {
        SUSPENDED_PAD *pad = generator->pads;
        generator->pads = pad->next;
        S_suspended_pad_restore(aTHX_ pad);
        S_suspended_pad_free(aTHX_ pad);
    }
}

static SUSPENDED_PAD *
S_generator_own_pad(pTHX_ PERL_GENERATOR *generator, CV *cv, I32 base)
{
    PADLIST *outside = CvPADLIST(cv);
    PADLIST *owned;
    SUSPENDED_PAD *pad;
    const I32 depth = CvDEPTH(cv);
    SSize_t i;
    assert(base >= 0 && base < depth);
    Newxz(pad, 1, SUSPENDED_PAD);
    Newx(owned, 1, PADLIST);
    *owned = *outside;
    PadlistMAX(owned) = depth;
    Newxz(PadlistARRAY(owned), depth + 1, PAD *);
    PadlistNAMES(owned) = PadnamelistREFCNT_inc(PadlistNAMES(outside));

    /* Keep live pad AVs intact. Only the spare recursion frames are new.
     * The outside padlist keeps its identity for callers below this owner. */
    for (i = 1; i <= depth; ++i) {
        PAD *frame = PadlistARRAY(outside)[i];
        if (i > base) {
            PadlistARRAY(owned)[i] = frame;
            PadlistARRAY(outside)[i] = pad_clone_frame(outside, frame, TRUE);
        }
        else
            PadlistARRAY(owned)[i] = pad_clone_frame(outside, frame, TRUE);
    }
    pad->cv = (CV *)SvREFCNT_inc_simple_NN(cv);
    pad->private_padlist = owned;
    pad->outside_padlist = outside;
    pad->private_depth = depth;
    pad->outside_depth = base;
    pad->installed = TRUE;
    pad->live = TRUE;
    pad->next = generator->pads;
    generator->pads = pad;
    S_suspended_pad_link(aTHX_ pad);
    CvPADLIST_set(cv, owned);
    return pad;
}

static void
S_generator_park_pads(pTHX_ PERL_GENERATOR *generator)
{
    SUSPENDED_PAD *pad;
    SUSPENDED_PAD **link;
    I32 i;
    const I32 oldsave = PL_savestack_ix;
    SAVEBOOL(generator->pads_switching);
    generator->pads_switching = TRUE;
    for (pad = generator->pads; pad; pad = pad->next)
        pad->live = FALSE;
    for (i = 0; i <= cxstack_ix; ++i) {
        PERL_CONTEXT *cx = &cxstack[i];
        CV *cv;
        if (CxTYPE(cx) != CXt_SUB)
            continue;
        cv = cx->blk_sub.cv;
        if (CvISXSUB(cv) || !CvPADLIST(cv))
            continue;
        for (pad = generator->pads; pad && pad->cv != cv; pad = pad->next)
            NOOP;
        if (!pad)
            pad = S_generator_own_pad(aTHX_ generator, cv, cx->blk_sub.olddepth);
        pad->live = TRUE;
    }
    /* Release completed activations while the private context and its
     * exception guard are still active. No callbacks run after detaching. */
    link = &generator->pads;
    while (*link) {
        pad = *link;
        if (pad->live) {
            link = &pad->next;
            continue;
        }
        *link = pad->next;
        S_suspended_pad_restore(aTHX_ pad);
        S_suspended_pad_free(aTHX_ pad);
    }
    for (pad = generator->pads; pad; pad = pad->next) {
        S_suspended_pad_unlink(aTHX_ pad);
        S_suspended_pad_link(aTHX_ pad);
    }
    if (generator->yield_pending)
        local_bindings_check(oldsave, generator->environment.rsgv);
    SV * const match_state = generator->yield_pending
        ? S_execution_matches_prepare(aTHX_ FALSE) : NULL;
    if (!local_bindings_park(&generator->local_bindings,
                             generator->environment.rsgv)) {
        if (generator->yield_pending)
            PERL_THROW_ERROR_ITERATOR_GENERATOR_LOCALIZATION_UNSUPPORTED();
        PERL_THROW_ERROR_ITERATOR_GENERATOR_CONTINUATION_UNAVAILABLE();
    }
    if (generator->yield_pending) {
        S_execution_matches_park(aTHX_ match_state);
        if (generator->match_state)
            sv_2mortal(generator->match_state);
        generator->match_state = SvREFCNT_inc(match_state);
    }
    S_generator_restore_pads(aTHX_ generator);
    LEAVE_SCOPE(oldsave);
}

static int
S_iterator_magic_free(pTHX_ SV *sv, MAGIC *mg)
{
    PERL_ITERATOR * const iterator = (PERL_ITERATOR *)mg->mg_ptr;
    PERL_UNUSED_ARG(sv);
    if (iterator) {
        Safefree(iterator);
        mg->mg_ptr = NULL;
    }
    return 0;
}

#ifdef USE_ITHREADS
static int
S_iterator_magic_dup(pTHX_ MAGIC *mg, CLONE_PARAMS *param)
{
    PERL_ITERATOR *copy;
    PERL_UNUSED_CONTEXT;
    PERL_UNUSED_ARG(param);
    Newx(copy, 1, PERL_ITERATOR);
    Copy(mg->mg_ptr, copy, 1, PERL_ITERATOR);
    mg->mg_ptr = (char *)copy;
    return 0;
}
#endif

static MGVTBL S_iterator_magic = {
    0, 0, 0, 0, S_iterator_magic_free,
    0,
#ifdef USE_ITHREADS
    S_iterator_magic_dup,
#else
    0,
#endif
    0
};

static PERL_ITERATOR *
S_iterator_from_sv(pTHX_ SV *sv)
{
    MAGIC *mg;

    if (sv && SvROK(sv))
        sv = SvRV(sv);
    if (!sv || SvTYPE(sv) != SVt_PVCV)
        return NULL;
    mg = mg_findext(sv, PERL_MAGIC_ext, &S_iterator_magic);
    return mg ? (PERL_ITERATOR *)mg->mg_ptr : NULL;
}

static bool
S_iterator_is_generator(pTHX_ SV *sv)
{
    if (sv && SvROK(sv))
        sv = SvRV(sv);
    return sv && SvTYPE(sv) == SVt_PVCV && CvISXSUB((CV *)sv)
        && CvXSUB((CV *)sv) == S_generator_xsub
        && (PERL_GENERATOR *)CvXSUBANY((CV *)sv).any_ptr
        && ((PERL_GENERATOR *)CvXSUBANY((CV *)sv).any_ptr)->magic
                                                        == PERL_GENERATOR_MAGIC;
}

static PERL_ITERATOR_STATE
S_iterator_state(pTHX_ SV *sv)
{
    PERL_ITERATOR * const iterator = S_iterator_from_sv(aTHX_ sv);
    if (iterator && iterator->magic == PERL_ITERATOR_MAGIC)
        return iterator->state;
    if (S_iterator_is_generator(aTHX_ sv)) {
        PERL_GENERATOR *generator;
        if (sv && SvROK(sv))
            sv = SvRV(sv);
        generator = (PERL_GENERATOR *)CvXSUBANY((CV *)sv).any_ptr;
        switch (generator->state) {
        case PERL_GENERATOR_EXHAUSTED:
            return PERL_ITERATOR_COMPLETED;
        case PERL_GENERATOR_FAILED:
            return PERL_ITERATOR_FAILED;
        default:
            return PERL_ITERATOR_RUNNING;
        }
    }
    return PERL_ITERATOR_INVALID;
}

bool
Perl_is_iter_adapter(pTHX_ SV *sv)
{
    PERL_ARGS_ASSERT_IS_ITER_ADAPTER;
    return sv && !SvGMAGICAL(sv) && SvROK(sv) && SvTYPE(SvRV(sv)) == SVt_PVCV
        && mg_findext(SvRV(sv), PERL_MAGIC_ext, &S_iter_adapter_magic);
}

SV *
Perl_iter_create(pTHX_ SV *source, SV *stop)
{
    dSP;
    SV *adapter;

    PERL_ARGS_ASSERT_ITER_CREATE;
    if (!stop && S_iterator_state(aTHX_ source) == PERL_ITERATOR_INVALID)
        PERL_THROW_ERROR_ITERATOR_STOP_REQUIRED();

    ENTER;
    SAVETMPS;
    SAVEVPTR(PL_curpm);
    if (!get_cv("iterator::_iter", 0)) {
        save_scalar(PL_errgv);
        load_module(PERL_LOADMOD_NOIMPORT, newSVpvs("iterator"), NULL);
    }
    SPAGAIN;
    PUSHMARK(SP);
    XPUSHs(source);
    if (stop)
        XPUSHs(stop);
    PUTBACK;
    call_pv("iterator::_iter", G_SCALAR);
    SPAGAIN;
    adapter = POPs;
    SAVEFREESV(SvREFCNT_inc_simple_NN(adapter));
    PUTBACK;
    FREETMPS;
    adapter = sv_mortalcopy(adapter);
    sv_magicext(SvRV(adapter), NULL, PERL_MAGIC_ext,
                &S_iter_adapter_magic, NULL, 0);
    LEAVE;
    return adapter;
}

/* A NULL result means completion. A yielded undef is an ordinary SV.
 * Keep the producer's temporaries and regex captures inside this call. */
SV *
Perl_iter_next(pTHX_ SV *adapter)
{
    const SSize_t base = PL_stack_sp - PL_stack_base;
    SV *value = NULL;
    I32 count;

    PERL_ARGS_ASSERT_ITER_NEXT;
    ENTER;
    SAVETMPS;
    SAVEVPTR(PL_curpm);
    PUSHMARK(PL_stack_sp);
    count = call_sv(adapter, G_LIST);
    if (count) {
        value = *PL_stack_sp;
        SAVEFREESV(SvREFCNT_inc_simple_NN(value));
    }
    rpp_popfree_to(PL_stack_base + base);
    FREETMPS;
    if (value)
        value = sv_mortalcopy(value);
    LEAVE;
    return value;
}


void
Perl_process_state_save(pTHX_ PERL_PROCESS_STATE *state)
{
    PERL_ARGS_ASSERT_PROCESS_STATE_SAVE;
#define PERLVAR(prefix,var,type)
#define PERLVARA(prefix,var,n,type)
#define PERLVARI(prefix,var,type,init)
#define PERLVARIC(prefix,var,type,init)
#define PERLVARCTX(prefix,var,type) \
    state->context.prefix##var = PL_##var;
#define PERLVARCTXI(prefix,var,type,init) PERLVARCTX(prefix,var,type)
#include "intrpvar.h"
#undef PERLVAR
#undef PERLVARA
#undef PERLVARI
#undef PERLVARIC
#undef PERLVARCTX
#undef PERLVARCTXI
}

void
Perl_process_state_restore(pTHX_ const PERL_PROCESS_STATE *state)
{
    PERL_ARGS_ASSERT_PROCESS_STATE_RESTORE;
#define PERLVAR(prefix,var,type)
#define PERLVARA(prefix,var,n,type)
#define PERLVARI(prefix,var,type,init)
#define PERLVARIC(prefix,var,type,init)
#define PERLVARCTX(prefix,var,type) \
    PL_##var = state->context.prefix##var;
#define PERLVARCTXI(prefix,var,type,init) PERLVARCTX(prefix,var,type)
#include "intrpvar.h"
#undef PERLVAR
#undef PERLVARA
#undef PERLVARI
#undef PERLVARIC
#undef PERLVARCTX
#undef PERLVARCTXI
}

void
Perl_process_state_capture(pTHX_ PERL_PROCESS_STATE *state)
{
    PERL_ARGS_ASSERT_PROCESS_STATE_CAPTURE;
    process_state_save(state);
}

static int
S_process_scheduler_boundary(pTHX_ OP *nextop, void *data)
{
    PERL_PROCESS_SCHEDULER * const scheduler = (PERL_PROCESS_SCHEDULER *)data;

    if (!nextop) {
        scheduler->done[scheduler->current] = TRUE;
        return PERL_RUNOPS_BOUNDARY_YIELD;
    }

    scheduler->boundaries++;
    scheduler->total_boundaries++;
    return scheduler->boundaries >= scheduler->quantum
        ? PERL_RUNOPS_BOUNDARY_YIELD : 0;
}

int
Perl_process_scheduler_run(pTHX_ PERL_PROCESS_SCHEDULER *scheduler)
{
    PERL_PROCESS_STATE caller_state;
    runops_proc_t old_runops = PL_runops;
    runops_boundary_proc_t old_hook = PL_runops_boundary_hook;
    void * const old_data = PL_runops_boundary_data;
    U8 i;
    bool all_done;

    PERL_ARGS_ASSERT_PROCESS_SCHEDULER_RUN;
    if (!scheduler->states || !scheduler->done || !scheduler->count
        || !scheduler->max_boundaries || scheduler->quantum == 0)
        return -1;

    process_state_save(&caller_state);
    scheduler->failure = 0;
    scheduler->boundaries = 0;
    scheduler->total_boundaries = 0;
    PL_runops = S_runops_with_boundary;

    do {
        all_done = TRUE;
        for (i = 0; i < scheduler->count; i++) {
            if (scheduler->done[i])
                continue;

            all_done = FALSE;
            scheduler->current = i;
            scheduler->boundaries = 0;
            process_state_restore(&scheduler->states[i]);
            if (!PL_op) {
                scheduler->done[i] = TRUE;
                continue;
            }
            PL_runops_boundary_hook = S_process_scheduler_boundary;
            PL_runops_boundary_data = scheduler;
            PL_runops(aTHX);
            process_state_save(&scheduler->states[i]);

            if (scheduler->total_boundaries >= scheduler->max_boundaries
                && !scheduler->done[i]) {
                scheduler->failure = 1;
                break;
            }
        }
    } while (!all_done && !scheduler->failure);

    PL_runops_boundary_hook = old_hook;
    PL_runops_boundary_data = old_data;
    PL_runops = old_runops;
    process_state_restore(&caller_state);
    return scheduler->failure ? -1 : 0;
}

PERL_GENERATOR *
Perl_generator_new(pTHX_ CV *body)
{
    PERL_GENERATOR *generator;
    AV *snapshot;
    SSize_t next = 0;
    const I32 floor = PL_savestack_ix;

    PERL_ARGS_ASSERT_GENERATOR_NEW;
    /* Creator magic can call Perl, throw, or clone the interpreter. Keep
     * every fallible snapshot under typed save-stack ownership before
     * allocating an execution record which cannot be cloned. */
    snapshot = newAV();
    SAVEFREESV(snapshot);
    av_extend(snapshot, 9);
    av_push(snapshot, SvREFCNT_inc(MUTABLE_SV(body)));
    av_push(snapshot, newSVsv(GvSV(PL_defgv)
                              ? GvSV(PL_defgv) : &PL_sv_undef));
    av_push(snapshot, MUTABLE_SV(newAV()));
    av_push(snapshot, newSV(0));
    av_push(snapshot, newSV(0));
    {
        GV * const rsgv = gv_fetchpvs("/", GV_ADD | GV_NOTQUAL, SVt_PV);
        SV *irs;
        av_push(snapshot, SvREFCNT_inc(MUTABLE_SV(rsgv)));
        irs = newSVsv(GvSVn(rsgv));
        av_push(snapshot, irs);
        sv_magic(irs, MUTABLE_SV(rsgv), PERL_MAGIC_sv, "/", 0);
    }
    av_push(snapshot, newSVsv(PL_rs));
    av_push(snapshot, MUTABLE_SV(hv_copy_hints_hv(GvHV(PL_hintgv))));
    av_push(snapshot, SvREFCNT_inc(MUTABLE_SV(PL_defoutgv)));

    Newxz(generator, 1, PERL_GENERATOR);
    generator->magic = PERL_GENERATOR_MAGIC;
#define TAKE_SNAPSHOT(field, type) STMT_START {                 \
    generator->field = (type)AvARRAY(snapshot)[next];           \
    AvARRAY(snapshot)[next++] = NULL;                          \
} STMT_END
    TAKE_SNAPSHOT(body, CV *);
    TAKE_SNAPSHOT(defsv, SV *);
    TAKE_SNAPSHOT(defav, AV *);
    TAKE_SNAPSHOT(errsv, SV *);
    TAKE_SNAPSHOT(errorobj, SV *);
    TAKE_SNAPSHOT(environment.rsgv, GV *);
    TAKE_SNAPSHOT(environment.irs, SV *);
    TAKE_SNAPSHOT(environment.rs, SV *);
    TAKE_SNAPSHOT(environment.hinthv, HV *);
    TAKE_SNAPSHOT(environment.defoutgv, GV *);
#undef TAKE_SNAPSHOT
    {
        PERL_GENERATOR_ENVIRONMENT * const environment = &generator->environment;
        environment->hints = PL_hints;
        environment->hints_hash = cophh_copy(CopHINTHASH_get(&PL_compiling));
        environment->features = PL_compiling.cop_features;
        environment->prevailing_version = PL_prevailing_version;
        environment->runops = PL_runops;
        environment->sig_local_owner = TRUE;
    }
    generator->invoke.op_ppaddr = PL_ppaddr[OP_ENTERSUB];
    generator->invoke.op_type = OP_ENTERSUB;
    generator->invoke.op_flags = OPf_STACKED | OPf_WANT_SCALAR;
    generator->state = PERL_GENERATOR_NEW;
    LEAVE_SCOPE(floor);
    return generator;
}

static int
S_generator_magic_free(pTHX_ SV *sv, MAGIC *mg)
{
    PERL_GENERATOR * const generator = (PERL_GENERATOR *)mg->mg_ptr;
    if (generator) {
        mg->mg_ptr = NULL;
        CvXSUBANY(MUTABLE_CV(sv)).any_ptr = NULL;
        generator_free(generator);
    }
    return 0;
}

static MGVTBL S_generator_magic = {
    0, 0, 0, 0, S_generator_magic_free,
    0, 0, 0
};

/* A generator's saved Perl stack belongs to the interpreter that created
 * it. We cannot copy that continuation into a new thread. */
static XS(XS_generator_clone_skip)
{
    dXSARGS;
    if (items != 1)
        croak_xs_usage(cv, "class");
    XSRETURN_YES;
}

static void
S_generator_xsub(pTHX_ CV *cv)
{
    dXSARGS;
    PERL_GENERATOR * const generator =
        (PERL_GENERATOR *)XSANY.any_ptr;
    AV *args;
    I32 i;

    if (!generator || generator->magic != PERL_GENERATOR_MAGIC)
        PERL_THROW_ERROR_ITERATOR_GENERATOR_INVALID_WRAPPER();
    if (generator->relay_token)
        PERL_THROW_ERROR_ASYNC_RELAY_BUSY();
    if (generator->awaiting)
        PERL_THROW_ERROR_ASYNC_GENERATOR_ADAPTER_REQUIRED();
    /* Argument cleanup can drop the caller's last wrapper reference. */
    SAVEFREESV(SvREFCNT_inc_simple_NN(cv));
    if (generator->pads_switching)
        PERL_THROW_ERROR_ITERATOR_GENERATOR_NO_SUSPENDED_CONTINUATION();
    if (generator->state == PERL_GENERATOR_EXHAUSTED
        || generator->state == PERL_GENERATOR_FAILED
        || (generator->state != PERL_GENERATOR_NEW && !generator->captured)) {
        generator_resume(generator, NULL);
        XSRETURN_EMPTY;
    }
    args = newAV();
    for (i = 0; i < items; i++)
        av_push(args, SvREFCNT_inc_simple(ST(i)));
    if (!generator_resume(generator, args)) {
        SSize_t i;
        AV * const result = generator->result;
        if (GIMME_V == G_SCALAR) {
            if (!result || AvFILLp(result) < 0)
                XSRETURN_EMPTY;
            ST(0) = sv_mortalcopy(*av_fetch(result, 0, 0));
            XSRETURN(1);
        }
        if (!result)
            XSRETURN_EMPTY;
        EXTEND(SP, AvFILLp(result) + 1);
        for (i = 0; i <= AvFILLp(result); i++)
            ST(i) = sv_mortalcopy(*av_fetch(result, i, 0));
        XSRETURN(AvFILLp(result) + 1);
    }
    {
        SSize_t i;
        AV * const values = generator->values;
        const SSize_t count = values ? AvFILLp(values) + 1 : 0;
        if (GIMME_V == G_SCALAR) {
            if (!count)
                XSRETURN_EMPTY;
            ST(0) = sv_mortalcopy(*av_fetch(values, 0, 0));
            XSRETURN(1);
        }
        if (GIMME_V == G_VOID)
            XSRETURN_EMPTY;
        EXTEND(SP, count);
        for (i = 0; i < count; i++)
            ST(i) = sv_mortalcopy(*av_fetch(values, i, 0));
        XSRETURN(count);
    }
}

SV *
Perl_generator_wrap(pTHX_ CV *body)
{
    CV *wrapper;
    PERL_GENERATOR *generator;
    SV *reference;

    PERL_ARGS_ASSERT_GENERATOR_WRAP;
    generator = generator_new(body);
    wrapper = newXS_flags(NULL, S_generator_xsub, __FILE__, NULL, 0);
    CvXSUBANY(wrapper).any_ptr = generator;
    sv_magicext(MUTABLE_SV(wrapper), NULL, PERL_MAGIC_ext,
                &S_generator_magic, (char *)generator, 0);
    reference = sv_2mortal(newRV_noinc(MUTABLE_SV(wrapper)));
    sv_bless(reference, gv_stashpvs("generator", GV_ADD));
    return reference;
}

static int
S_async_relay_free(pTHX_ SV *token, MAGIC *magic)
{
    CV * const wrapper = MUTABLE_CV(magic->mg_obj);
    PERL_GENERATOR * const owner = (PERL_GENERATOR *)CvXSUBANY(wrapper).any_ptr;
    PERL_UNUSED_CONTEXT;
    if (owner && owner->relay_token == token)
        owner->relay_token = NULL;
    return 0;
}

static MGVTBL S_async_relay_magic = {
    0, 0, 0, 0, S_async_relay_free, 0, 0, 0
};

static XS(S_async_claim)
{
    dXSARGS;
    CV *wrapper;
    PERL_GENERATOR *owner;
    SV *token, *reference;
    if (items != 1)
        croak_xs_usage(cv, "generator");
    if (!S_iterator_is_generator(aTHX_ ST(0)))
        PERL_THROW_ERROR_ASYNC_FIBER_REQUIRED();
    wrapper = MUTABLE_CV(SvRV(ST(0)));
    owner = (PERL_GENERATOR *)CvXSUBANY(wrapper).any_ptr;
    if (owner->relay_token)
        PERL_THROW_ERROR_ASYNC_RELAY_BUSY();
    if (owner->state == PERL_GENERATOR_RUNNING || owner->pads_switching)
        PERL_THROW_ERROR_ASYNC_FIBER_RUNNING();
    reference = sv_2mortal(newRV_noinc(newSV(0)));
    token = SvRV(reference);
    /* The token owns the wrapper. The execution borrows the token, so there
     * is no ownership cycle. Scope unwind releases the claim on cancellation
     * and exceptions as well as on a normal generator yield. */
    sv_magicext(token, MUTABLE_SV(wrapper), PERL_MAGIC_ext,
                &S_async_relay_magic, NULL, 0);
    owner->relay_token = token;
    sv_bless(reference, gv_stashpvs("XPerl::_Relay", GV_ADD));
    ST(0) = reference;
    XSRETURN(1);
}

SV *
Perl_async_wrap(pTHX_ CV *body)
{
    CV *wrapper;
    PERL_ARGS_ASSERT_ASYNC_WRAP;
    wrapper = newXS_flags(NULL, S_async_factory, CvFILE(body), NULL, XS_DYNAMIC_FILENAME);
    /* This existing CV ownership flag also makes interpreter cloning retain
     * the cloned body, rather than a pointer into the parent interpreter. */
    CvXSUBANY(wrapper).any_sv = SvREFCNT_inc(MUTABLE_SV(body));
    CvREFCOUNTED_ANYSV_on(wrapper);
    CvASYNC_on(wrapper);
    CvFLAGS(wrapper) |= CvFLAGS(body) & (CVf_IsMETHOD | PERL_CVf_MULTISUB);
    CvSTASH_set(wrapper, CvSTASH(body));
    if (SvPOK(body))
        sv_setpvn(MUTABLE_SV(wrapper), SvPVX(body), SvCUR(body));
    return sv_2mortal(newRV_noinc(MUTABLE_SV(wrapper)));
}

void
Perl_async_check_name(pTHX_ OP *nameop)
{
    STRLEN length;
    const char *name, *end, *part;
    PERL_ARGS_ASSERT_ASYNC_CHECK_NAME;
    if (nameop->op_type != OP_CONST)
        return;
    name = SvPV(cSVOPx(nameop)->op_sv, length);
    end = name + length;
    part = name;
    while (name < end) {
        if (*name == ':' || *name == '\'')
            part = name + 1;
        name++;
    }
    length = end - part;
    /* Phase subs can run during compilation. Automatic destruction ignores
     * returned tasks and needs synchronous cleanup. Reject both kinds before
     * newATTRSUB can register their hooks. */
    if (memEQs(part, length, "BEGIN") || memEQs(part, length, "UNITCHECK")
        || memEQs(part, length, "CHECK") || memEQs(part, length, "INIT")
        || memEQs(part, length, "END") || memEQs(part, length, "DESTROY")
        || memEQs(part, length, "TEARDOWN"))
        PERL_THROW_ERROR_ASYNC_DECLARATION_UNSUPPORTED();
}

CV *
Perl_async_lexical_factory(pTHX_ CV *target, CV *body)
{
    PERL_ARGS_ASSERT_ASYNC_LEXICAL_FACTORY;
    /* Keep the lexical name in its original pad slot. The factory owns a
     * separate Perl body, so normal closure cloning can bind its captures
     * without adding a Perl wrapper frame or recreating state variables. */
    cv_undef(target);
    if (CvOUTSIDE(target) && !CvWEAKOUTSIDE(target))
        SvREFCNT_dec(CvOUTSIDE(target));
    CvOUTSIDE(target) = NULL;
    CvWEAKOUTSIDE_off(target);
    CvISXSUB_on(target);
    CvXSUB(target) = S_async_factory;
    CvXSUBANY(target).any_sv = SvREFCNT_inc(MUTABLE_SV(body));
    CvREFCOUNTED_ANYSV_on(target);
#ifndef MULTIPLICITY
    CvHSCXT(target) = &PL_stack_sp;
#else
    PoisonPADLIST(target);
#endif
    CvASYNC_on(target);
    CvLEXICAL_on(target);
    CvFLAGS(target) |= CvFLAGS(body) & (CVf_CLONE | CVf_CLONED);
    CvFLAGS(target) |= CvFLAGS(body) & CVf_IsMETHOD;
    CvNAME_HEK_set(target, share_hek_hek(CvNAME_HEK(body)));
    CvFILE(target) = savepv(CvFILE(body));
    CvDYNFILE_on(target);
    CvSTASH_set(target, CvSTASH(body));
    CvOUTSIDE(target) = CvOUTSIDE(body);
    CvOUTSIDE_SEQ(target) = CvOUTSIDE_SEQ(body);
    if (CvWEAKOUTSIDE(body))
        CvWEAKOUTSIDE_on(target);
    else
        SvREFCNT_inc(CvOUTSIDE(target));
    if (SvPOK(body)) {
        sv_setpvn(MUTABLE_SV(target), SvPVX(body), SvCUR(body));
        if (SvUTF8(body))
            SvUTF8_on(target);
    }
    return target;
}

void
Perl_async_install(pTHX_ CV *body)
{
    SV *reference;
    CV *wrapper;
    GV *gv;
    PERL_ARGS_ASSERT_ASYNC_INSTALL;
    if (!CvROOT(body) || CvLEXICAL(body) || CvLVALUE(body)
        || !(gv = CvGV(body)) || GvCV(gv) != body)
        PERL_THROW_ERROR_ASYNC_DECLARATION_UNSUPPORTED();
    const I32 floor = PL_savestack_ix;
    SAVEFREESV(SvREFCNT_inc(MUTABLE_SV(gv)));
    CvASYNC_on(body);
    reference = async_wrap(body);
    wrapper = MUTABLE_CV(SvRV(reference));
    CvGV_set(wrapper, NULL);
    CvSTASH_set(wrapper, CvSTASH(body));
    GvCV_set(gv, MUTABLE_CV(SvREFCNT_inc(MUTABLE_SV(wrapper))));
    CvANON_off(wrapper);
    CvGV_set(wrapper, gv);
    SvREFCNT_dec(MUTABLE_SV(body));
    gv_method_changed(gv);
    LEAVE_SCOPE(floor);
}

void
Perl_async_install_multi(pTHX_ CV *body, SV *name)
{
    STRLEN length;
    const char * const fullname = SvPV(name, length);
    GV * const gv = gv_fetchsv(name, GV_NOADD_NOINIT, SVt_PVCV);
    CV * const reserved = GvCV(gv);
    CV *wrapper;
    PERL_ARGS_ASSERT_ASYNC_INSTALL_MULTI;
    /* newXS reuses the group's empty reservation. Replacing the glob's CV
     * would leave early code references calling the raw dispatch body. */
    assert(CvMULTISUB(reserved) && !CvROOT(reserved) && !CvISXSUB(reserved));
    GvASSUMECV_off(gv);
    wrapper = newXS_len_flags(fullname, length, S_async_factory, CvFILE(body),
        NULL, NULL, XS_DYNAMIC_FILENAME | (SvUTF8(name) ? SVf_UTF8 : 0));
    assert(wrapper == reserved);
    PERL_UNUSED_VAR(reserved);
    CvXSUBANY(wrapper).any_sv = SvREFCNT_inc(MUTABLE_SV(body));
    CvREFCOUNTED_ANYSV_on(wrapper);
    CvASYNC_on(wrapper);
    CvMULTISUB_on(wrapper);
    CvFLAGS(wrapper) |= CvFLAGS(body) & CVf_IsMETHOD;
    CvSTASH_set(wrapper, CvSTASH(body));
    gv_method_changed(gv);
}

void
Perl_async_load(pTHX)
{
    I32 floor;
    PERL_ARGS_ASSERT_ASYNC_LOAD;
    if (get_cv("XPerl::Task::_run", 0))
        return;
    floor = PL_savestack_ix;
    /* Loading the driver is an implementation detail of task creation.
     * A successful load must not clear the caller's existing exception. */
    save_scalar(PL_errgv);
    save_scalar(PL_errorobjgv);
    load_module(PERL_LOADMOD_NOIMPORT, newSVpvs("XPerl::Task"), NULL, NULL);
    LEAVE_SCOPE(floor);
}

static AV *
S_async_callsite(pTHX)
{
    const COP *source;
    AV *site;
    SV *hint;
    if (!PL_curcop)
        return NULL;
    source = PL_op
        ? closest_cop(PL_curcop, OpSIBLING(PL_curcop), PL_op, FALSE) : PL_curcop;
    if (!source)
        source = PL_curcop;
    /* Keep diagnostic metadata, not the caller's optree or package. Either
     * can disappear before dispatch starts. An absent language hint must
     * keep using the mutable render default rather than the driver's hint. */
    site = MUTABLE_AV(sv_2mortal(MUTABLE_SV(newAV())));
    av_push(site, newSVpv(OutCopFILE(source), 0));
    av_push(site, newSVuv(CopLINE(source)));
    hint = cop_hints_fetch_pvs(source, PERL_DIAGPACK_HINT_KEY, 0);
    av_push(site, newSVuv(hint && SvIOK(hint) ? SvUV(hint) : 0));
    return site;
}

static XS(S_async_factory)
{
    dXSARGS;
    CV * const body = MUTABLE_CV(CvXSUBANY(cv).any_sv);
    SV *fiber;
    AV *args;
    I32 i;
    AV * const callsite = CvMULTISUB(body) ? S_async_callsite(aTHX) : NULL;
    PUTBACK;
    /* Snapshotting the creator's environment can run magic. Keep the
     * selected receiver before that code can reassign the caller's scalar. */
    SV * const invocant = items && CvIsMETHOD(body)
        ? sv_2mortal(newSVsv(ST(0))) : NULL;
    async_load();
    fiber = generator_wrap(body);
    ((PERL_GENERATOR *)CvXSUBANY(MUTABLE_CV(SvRV(fiber))).any_ptr)->callsite
        = MUTABLE_AV(SvREFCNT_inc(MUTABLE_SV(callsite)));
    sv_bless(fiber, gv_stashpvs("XPerl::_Fiber", GV_ADD));
    args = newAV();
    sv_2mortal(MUTABLE_SV(args));
    for (i = 0; i < items; i++) {
        /* Dispatch has selected a method for this object. Reassigning the
         * caller's scalar must not change that pending call's invocant. */
        av_push(args, SvREFCNT_inc(i == 0 && invocant ? invocant : ST(i)));
    }
    SPAGAIN;
    SP -= items;
    PUSHMARK(SP);
    XPUSHs(fiber);
    XPUSHs(sv_2mortal(newRV_inc(MUTABLE_SV(args))));
    PUTBACK;
    call_pv("XPerl::Task::_new", G_SCALAR);
    SPAGAIN;
    ST(0) = POPs;
    XSRETURN(1);
}

static XS(S_async_step)
{
    dXSARGS;
    PERL_GENERATOR *generator;
    AV *args, *packet;
    SSize_t i;
    I32 floor;
    if (items != 4)
        croak_xs_usage(cv, "fiber, arguments, exception, relay");
    if (!S_iterator_is_generator(aTHX_ ST(0)))
        PERL_THROW_ERROR_ASYNC_FIBER_REQUIRED();
    generator = (PERL_GENERATOR *)CvXSUBANY(MUTABLE_CV(SvRV(ST(0)))).any_ptr;
    if (generator->relay_token
        && (!SvROK(ST(3)) || SvRV(ST(3)) != generator->relay_token))
        PERL_THROW_ERROR_ASYNC_RELAY_BUSY();
    if (generator->state == PERL_GENERATOR_RUNNING || generator->pads_switching)
        PERL_THROW_ERROR_ASYNC_FIBER_RUNNING();
    if (SvOK(ST(1)) && (!SvROK(ST(1)) || SvTYPE(SvRV(ST(1))) != SVt_PVAV))
        PERL_THROW_ERROR_ASYNC_FIBER_REQUIRED();
    if (SvOK(ST(2)) && generator->state != PERL_GENERATOR_YIELDED)
        PERL_THROW_ERROR_ASYNC_EXCEPTION_REQUIRES_SUSPENSION();
    floor = PL_savestack_ix;
    SAVEFREESV(SvREFCNT_inc(SvRV(ST(0))));
    SAVEBOOL(generator->await_allowed);
    SAVEBOOL(generator->pads_switching);
    generator->pads_switching = TRUE;
    generator->await_allowed = TRUE;
    args = newAV();
    SAVEFREESV(args);
    if (SvOK(ST(1))) {
        AV * const source = MUTABLE_AV(SvRV(ST(1)));
        for (i = 0; i <= AvFILLp(source); i++) {
            SV **svp = av_fetch(source, i, 0);
            av_push(args, SvREFCNT_inc(svp ? *svp : &PL_sv_undef));
        }
    }
    {
        SV * const old = generator->resume_exception;
        generator->resume_exception = NULL;
        SvREFCNT_dec(old);
    }
    generator->resume_exception = SvOK(ST(2)) ? newSVsv(ST(2)) : NULL;
    generator->pads_switching = FALSE;
    if (generator->awaiting && !SvOK(ST(1)) && !SvOK(ST(2))) {
        /* A replacement adapter first waits for the dependency saved by the
         * old one. It must not resume that await with an invented undef. */
    }
    else if (generator->state == PERL_GENERATOR_EXHAUSTED
             || generator->state == PERL_GENERATOR_FAILED) {
        generator_resume(generator, NULL);
    }
    else {
        if (generator->state != PERL_GENERATOR_NEW && !generator->captured)
            PERL_THROW_ERROR_ASYNC_EXCEPTION_REQUIRES_SUSPENSION();
        generator_resume(generator, MUTABLE_AV(SvREFCNT_inc(MUTABLE_SV(args))));
    }
    generator->pads_switching = TRUE;
    packet = newAV();
    sv_2mortal(MUTABLE_SV(packet));
    av_push(packet, newSViv(generator->state == PERL_GENERATOR_EXHAUSTED ? 0
                           : generator->awaiting ? 2 : 1));
    {
        SV **result = generator->result ? av_fetch(generator->result, 0, 0) : NULL;
        SV * const value = generator->state == PERL_GENERATOR_EXHAUSTED
            ? (result ? *result : &PL_sv_undef)
            : (generator->value ? generator->value : &PL_sv_undef);
        av_push(packet, newSVsv(value));
    }
    LEAVE_SCOPE(floor);
    ST(0) = sv_2mortal(newRV_inc(MUTABLE_SV(packet)));
    XSRETURN(1);
}

static XS(S_async_close)
{
    dXSARGS;
    CV *wrapper;
    PERL_GENERATOR *generator;
    MAGIC *magic;
    if (items != 1)
        croak_xs_usage(cv, "fiber");
    if (!S_iterator_is_generator(aTHX_ ST(0)))
        PERL_THROW_ERROR_ASYNC_FIBER_REQUIRED();
    wrapper = MUTABLE_CV(SvRV(ST(0)));
    generator = (PERL_GENERATOR *)CvXSUBANY(wrapper).any_ptr;
    if (generator->state == PERL_GENERATOR_RUNNING || generator->pads_switching)
        PERL_THROW_ERROR_ASYNC_FIBER_RUNNING();
    if (generator->relay_token)
        PERL_THROW_ERROR_ASYNC_RELAY_BUSY();
    magic = mg_findext(MUTABLE_SV(wrapper), PERL_MAGIC_ext, &S_generator_magic);
    magic->mg_ptr = NULL;
    CvXSUBANY(wrapper).any_ptr = NULL;
    generator_free(generator);
    XSRETURN_EMPTY;
}

static XS(XS_iterator_new)
{
    dXSARGS;
    SV *iterator_sv;
    CV *iterator_cv;

    if (items == 2 && !SvROK(ST(0)))
        iterator_sv = ST(1);
    else if (items == 1)
        iterator_sv = ST(0);
    else
        croak_xs_usage(cv, "coderef");

    if (!SvROK(iterator_sv) || SvTYPE(SvRV(iterator_sv)) != SVt_PVCV)
        PERL_THROW_ERROR_ITERATOR_CONSTRUCTOR_CODE_REFERENCE_REQUIRED();

    iterator_cv = MUTABLE_CV(SvRV(iterator_sv));
    if (!S_iterator_from_sv(aTHX_ iterator_sv)) {
        PERL_ITERATOR *iterator;
        Newxz(iterator, 1, PERL_ITERATOR);
        iterator->magic = PERL_ITERATOR_MAGIC;
        iterator->state = PERL_ITERATOR_RUNNING;
        MAGIC *mg = sv_magicext(MUTABLE_SV(iterator_cv), NULL, PERL_MAGIC_ext,
                               &S_iterator_magic, (char *)iterator, 0);
        mg->mg_flags |= MGf_DUP;
    }
    sv_bless(iterator_sv, gv_stashpvs("iterator", GV_ADD));
    ST(0) = iterator_sv;
    XSRETURN(1);
}

static XS(XS_iterator_state)
{
    dXSARGS;
    PERL_ITERATOR_STATE state;

    if (items != 1)
        croak_xs_usage(cv, "iterator");
    state = S_iterator_state(aTHX_ ST(0));
    if (state == PERL_ITERATOR_INVALID)
        XSRETURN_UNDEF;
    XSRETURN_UV((UV)state);
}

static XS(XS_iterator_set_state)
{
    dXSARGS;
    SV *iterator_sv;
    PERL_ITERATOR *iterator;
    const UV state = items == 2 ? SvUV(ST(1)) : 0;

    if (items != 2)
        croak_xs_usage(cv, "iterator, state");
    iterator_sv = ST(0);
    iterator = S_iterator_from_sv(aTHX_ iterator_sv);
    if (!iterator || iterator->magic != PERL_ITERATOR_MAGIC) {
        if (S_iterator_is_generator(aTHX_ iterator_sv))
            PERL_THROW_ERROR_ITERATOR_GENERATOR_STATE_MUTATION_FORBIDDEN();
        XSRETURN_UNDEF;
    }
    if (state == PERL_ITERATOR_INVALID || state > PERL_ITERATOR_FAILED)
        PERL_THROW_ERROR_ITERATOR_INVALID_STATE();
    iterator->state = (PERL_ITERATOR_STATE)state;
    ST(0) = iterator_sv;
    XSRETURN(1);
}

static XS(XS_iterator_exhausted)
{
    dXSARGS;
    const PERL_ITERATOR_STATE state = items == 1
        ? S_iterator_state(aTHX_ ST(0)) : PERL_ITERATOR_INVALID;
    if (items != 1)
        croak_xs_usage(cv, "iterator");
    if (state == PERL_ITERATOR_INVALID)
        XSRETURN_UNDEF;
    ST(0) = boolSV(state == PERL_ITERATOR_COMPLETED
                || state == PERL_ITERATOR_FAILED);
    XSRETURN(1);
}

static XS(XS_iterator_completed)
{
    dXSARGS;
    const PERL_ITERATOR_STATE state = items == 1
        ? S_iterator_state(aTHX_ ST(0)) : PERL_ITERATOR_INVALID;
    if (items != 1)
        croak_xs_usage(cv, "iterator");
    if (state == PERL_ITERATOR_INVALID)
        XSRETURN_UNDEF;
    ST(0) = boolSV(state == PERL_ITERATOR_COMPLETED);
    XSRETURN(1);
}

static XS(XS_iterator_failed)
{
    dXSARGS;
    const PERL_ITERATOR_STATE state = items == 1
        ? S_iterator_state(aTHX_ ST(0)) : PERL_ITERATOR_INVALID;
    if (items != 1)
        croak_xs_usage(cv, "iterator");
    if (state == PERL_ITERATOR_INVALID)
        XSRETURN_UNDEF;
    ST(0) = boolSV(state == PERL_ITERATOR_FAILED);
    XSRETURN(1);
}

static XS(XS_iterator_running)
{
    dXSARGS;
    const PERL_ITERATOR_STATE state = items == 1
        ? S_iterator_state(aTHX_ ST(0)) : PERL_ITERATOR_INVALID;
    if (items != 1)
        croak_xs_usage(cv, "iterator");
    if (state == PERL_ITERATOR_INVALID)
        XSRETURN_UNDEF;
    ST(0) = boolSV(state == PERL_ITERATOR_RUNNING);
    XSRETURN(1);
}

static XS(XS_generator_exhausted)
{
    dXSARGS;
    if (items != 1)
        croak_xs_usage(cv, "generator");
    if (!generator_is_valid(ST(0)))
        XSRETURN_UNDEF;
    ST(0) = boolSV(generator_is_exhausted(ST(0)));
    XSRETURN(1);
}

static XS(XS_generator_completed)
{
    dXSARGS;
    if (items != 1)
        croak_xs_usage(cv, "generator");
    if (!generator_is_valid(ST(0)))
        XSRETURN_UNDEF;
    ST(0) = boolSV(generator_is_completed(ST(0)));
    XSRETURN(1);
}

static XS(XS_generator_failed)
{
    dXSARGS;
    if (items != 1)
        croak_xs_usage(cv, "generator");
    if (!generator_is_valid(ST(0)))
        XSRETURN_UNDEF;
    ST(0) = boolSV(generator_is_failed(ST(0)));
    XSRETURN(1);
}

static XS(XS_generator_running)
{
    dXSARGS;
    int i;
    int out = 0;

    if (items == 1 && GIMME_V == G_SCALAR) {
        if (!generator_is_valid(ST(0)))
            XSRETURN_UNDEF;
        ST(0) = boolSV(generator_is_running(ST(0)));
        XSRETURN(1);
    }

    for (i = 0; i < items; i++) {
        if (!generator_is_valid(ST(i)))
            PERL_THROW_ERROR_ITERATOR_GENERATOR_RUNNING_INVALID_ARGUMENT();
        if (generator_is_running(ST(i)))
            ST(out++) = ST(i);
    }
    XSRETURN(out);
}

void
Perl_boot_core_generator(pTHX)
{
    PERL_ARGS_ASSERT_BOOT_CORE_GENERATOR;
    newXS_flags("XPerl::Task::_step", S_async_step, __FILE__, "$$$$", 0);
    newXS_flags("XPerl::Task::_claim", S_async_claim, __FILE__, "$", 0);
    newXS_flags("XPerl::Task::_close", S_async_close, __FILE__, "$", 0);
    newXS_flags("XPerl::_Fiber::CLONE_SKIP", XS_generator_clone_skip, __FILE__, "$", 0);
    newXS_flags("XPerl::_Relay::CLONE_SKIP", XS_generator_clone_skip, __FILE__, "$", 0);
    newXS_flags("iterator::new", &XS_iterator_new,
                __FILE__, "$", 0);
    newXS_flags("iterator::state", &XS_iterator_state,
                __FILE__, "$", 0);
    newXS_flags("iterator::set_state", &XS_iterator_set_state,
                __FILE__, "$$", 0);
    newXS_flags("iterator::exhausted", &XS_iterator_exhausted,
                __FILE__, "$", 0);
    newXS_flags("iterator::completed", &XS_iterator_completed,
                __FILE__, "$", 0);
    newXS_flags("iterator::failed", &XS_iterator_failed,
                __FILE__, "$", 0);
    newXS_flags("iterator::running", &XS_iterator_running,
                __FILE__, "$", 0);
    newXS_flags("generator::exhausted", &XS_generator_exhausted,
                __FILE__, "$", 0);
    newXS_flags("generator::completed", &XS_generator_completed,
                __FILE__, "$", 0);
    newXS_flags("generator::failed", &XS_generator_failed,
                __FILE__, "$", 0);
    newXS_flags("generator::running", &XS_generator_running,
                __FILE__, "@", 0);
    newXS_flags("generator::CLONE_SKIP", &XS_generator_clone_skip,
                __FILE__, "$", 0);
}

static void S_generator_pop_stackinfo(pTHX_ PERL_GENERATOR *generator);
static void S_generator_detach_stackinfo(pTHX_ PERL_GENERATOR *generator);
static void S_generator_attach_stackinfo(pTHX_ PERL_GENERATOR *generator);

static void
S_generator_swap_environment(pTHX_ PERL_GENERATOR *generator, bool entering)
{
    /* Exchange the bindings and their interpreter backing state together.
     * For example, reading $/ uses its GV, while readline uses PL_rs.
     * Neither half of that setting may remain in the caller's environment.
     * These exchanges call no magic and run no Perl code. */
#define SWAP_ENV(field, slot, type) STMT_START { \
    type const saved = (slot);                 \
    (slot) = generator->environment.field;      \
    generator->environment.field = saved;       \
} STMT_END
    /* Two roots may share a glob slot. Reverse the exchanges on departure
     * so that this remains an inverse even when, for example, $/ aliases $_. */
    if (!entering)
        SWAP_ENV(irs, GvSV(generator->environment.rsgv), SV *);
#define SWAP_DEFAULT(field, slot, type) STMT_START { \
    type const saved = (slot);                     \
    (slot) = generator->field;                     \
    generator->field = saved;                      \
} STMT_END
    if (entering) {
        SWAP_DEFAULT(defsv, GvSV(PL_defgv), SV *);
        SWAP_DEFAULT(defav, GvAV(PL_defgv), AV *);
        SWAP_DEFAULT(errsv, GvSV(PL_errgv), SV *);
        SWAP_DEFAULT(errorobj, GvSV(PL_errorobjgv), SV *);
        SWAP_ENV(irs, GvSV(generator->environment.rsgv), SV *);
    }
    else {
        SWAP_DEFAULT(errorobj, GvSV(PL_errorobjgv), SV *);
        SWAP_DEFAULT(errsv, GvSV(PL_errgv), SV *);
        SWAP_DEFAULT(defav, GvAV(PL_defgv), AV *);
        SWAP_DEFAULT(defsv, GvSV(PL_defgv), SV *);
    }
#undef SWAP_DEFAULT
    SWAP_ENV(rs, PL_rs, SV *);
    SWAP_ENV(hinthv, GvHV(PL_hintgv), HV *);
    SWAP_ENV(sig_local_owner, PL_sig_local_owner, bool);
    SWAP_ENV(defoutgv, PL_defoutgv, GV *);
    SWAP_ENV(sortcop, PL_sortcop, OP *);
    SWAP_ENV(sortstash, PL_sortstash, HV *);
    SWAP_ENV(compcv, PL_compcv, CV *);
    SWAP_ENV(comppad_name, PL_comppad_name, PADNAMELIST *);
    SWAP_ENV(comppad_name_fill, PL_comppad_name_fill, PADOFFSET);
    SWAP_ENV(comppad_name_floor, PL_comppad_name_floor, PADOFFSET);
    SWAP_ENV(hints, PL_hints, U32);
    SWAP_ENV(hints_hash, PL_compiling.cop_hints_hash, COPHH *);
    SWAP_ENV(features, PL_compiling.cop_features, struct cop_feature_t);
    SWAP_ENV(prevailing_version, PL_prevailing_version, U16);
    SWAP_ENV(parser, PL_parser, yy_parser *);
    SWAP_ENV(runops, PL_runops, runops_proc_t);
#undef SWAP_ENV
}

static void
S_generator_free_tmps(pTHX_ PERL_PROCESS_STATE *process)
{
    PERL_EXECUTION_CONTEXT * const context = &process->context;
    while (context->Itmps_ix >= 0) {
        SV * const sv = context->Itmps_stack[context->Itmps_ix--];
        if (sv) {
            SvTEMP_off(sv);
            SvREFCNT_dec_NN(sv);
        }
    }
}

static void
S_generator_free_process_stacks(pTHX_ PERL_PROCESS_STATE *process)
{
    PERL_EXECUTION_CONTEXT * const context = &process->context;
    S_generator_free_tmps(aTHX_ process);
    Safefree(context->Imarkstack);
    Safefree(context->Isavestack);
    Safefree(context->Iscopestack);
#ifdef DEBUGGING
    Safefree(context->Iscopestack_name);
    context->Iscopestack_name = NULL;
#endif
    Safefree(context->Itmps_stack);
    context->Imarkstack = NULL;
    context->Isavestack = NULL;
    context->Iscopestack = NULL;
    context->Itmps_stack = NULL;
}

static void
S_generator_warn_cleanup(pTHX_ void *data)
{
    const I32 index = PTR2IV(data);
    AV * const errors = MUTABLE_AV(PL_savestack[index].any_sv);
    SSize_t i;

    for (i = 0; i <= AvFILLp(errors); ++i)
        PERL_WARN_WARNING_MISC_EXCEPTION_DURING_CLEANUP(AvARRAY(errors)[i]);
}

static void
S_generator_defer_cleanup_errors(pTHX_ AV *errors)
{
    const I32 index = PL_savestack_ix;
    /* A warning hook can throw. Wait until the free-magic callback has
     * returned so reporting cannot interrupt the wrapper's destruction.
     * A typed save entry lets a cloned interpreter own its copy of the
     * diagnostics. Pass its index rather than a pointer to the AV. */
    SAVEFREESV(errors);
    SAVEDESTRUCTOR_X(S_generator_warn_cleanup, INT2PTR(void *, (IV)index));
}

static void
S_generator_unwind(pTHX_ PERL_GENERATOR *generator, JMPENV *env)
{
    I32 i;
    /* Cleanup must not jump into a handler in the abandoned body. */
    for (i = 0; i <= cxstack_ix; ++i) {
        if (CxTYPE(&cxstack[i]) == CXt_EVAL) {
            cxstack[i].blk_eval.cur_top_env = env;
            cxstack[i].blk_eval.retop = NULL;
        }
    }
    dounwind(-1);
    generator->eval_active = FALSE;

    /* Destructors can grow the private stacks and create more temporaries.
     * Keep a live eval while draining them, including after process exit
     * has unwound the body's original eval frames. */
    PL_op = (OP *)&generator->invoke;
    create_eval_scope(NULL, PL_stack_base, G_FAKINGEVAL);
    rpp_obliterate_stack_to(0);
    PL_tmps_floor = -1;
    FREETMPS;
    dounwind(-1);
    process_state_save(&generator->process);
}

void
Perl_generator_free(pTHX_ PERL_GENERATOR *generator)
{
    PERL_PROCESS_STATE caller_state;
    SV *caller_matches = NULL;
    AV * volatile cleanup_errors = NULL;
    volatile bool exiting = FALSE;

    PERL_ARGS_ASSERT_GENERATOR_FREE;
    if (generator->stack_pushed) {
        if (PL_phase == PERL_PHASE_DESTRUCT) {
            /* The interpreter's normal context stack is already being torn
             * down.  Do not run scope cleanup against that stack here; the
             * generator's private stack is about to be purged with the rest
             * of the interpreter.  Relink it so S_nuke_stacks() can reclaim
             * its context stack, but do not switch the active PL_* pointers. */
            if (generator->stack_detached)
                S_generator_attach_stackinfo(aTHX_ generator);
            S_generator_free_process_stacks(aTHX_ &generator->process);
            CvDEPTH(generator->body) = 0;
            generator->eval_active = FALSE;
            generator->stack_pushed = FALSE;
        }
        else {
            runops_boundary_proc_t const old_hook = PL_runops_boundary_hook;
            void * const old_data = PL_runops_boundary_data;
            JMPENV * const old_restartjmpenv = PL_restartjmpenv;
            int ret;
            dJMPENV;

            caller_matches = S_execution_matches_prepare(aTHX_ TRUE);
            S_execution_matches_park(aTHX_ caller_matches);
            process_state_save(&caller_state);
            if (generator->stack_detached)
                S_generator_attach_stackinfo(aTHX_ generator);
            S_generator_install_pads(aTHX_ generator);
            process_state_restore(&generator->process);
            if (generator->match_state)
                S_execution_matches_restore(aTHX_ generator->match_state);
            const bool bindings_valid = local_bindings_validate(
                generator->local_bindings, &generator->process,
                generator->environment.rsgv);
            /* Locals can use the same slots as the owner's defaults.
             * Install the defaults first, then replay the inner bindings.
             * Parking removes those bindings in the opposite order. */
            S_generator_swap_environment(aTHX_ generator, TRUE);
            if (bindings_valid)
                local_bindings_resume(generator->local_bindings, PL_savestack);
            else
                local_bindings_discard(generator->local_bindings, PL_savestack);
            PL_runops_boundary_hook = NULL;
            PL_runops_boundary_data = NULL;
            JMPENV_PUSH(ret);
            if (ret == 2)
                exiting = TRUE;
            if (ret && ret != 2 && ret != 3) {
                process_state_save(&generator->process);
                JMPENV_POP;
                S_generator_restore_pads(aTHX_ generator);
                S_generator_swap_environment(aTHX_ generator, FALSE);
                process_state_restore(&caller_state);
                S_execution_matches_restore(aTHX_ caller_matches);
                PL_runops_boundary_hook = old_hook;
                PL_runops_boundary_data = old_data;
                PL_restartjmpenv = old_restartjmpenv;
                JMPENV_JUMP(ret);
            }
            if (ret == 3) {
                SV * const error = SvROK(PERL_ERROR_OBJ) ? PERL_ERROR_OBJ : ERRSV;
                if (!cleanup_errors)
                    cleanup_errors = newAV();
                av_push(cleanup_errors, newSVsv(error));
            }
            S_generator_unwind(aTHX_ generator, &cur_env);
            JMPENV_POP;
            S_generator_pop_stackinfo(aTHX_ generator);
            S_generator_restore_pads(aTHX_ generator);
            S_generator_swap_environment(aTHX_ generator, FALSE);
            process_state_restore(&caller_state);
            S_execution_matches_restore(aTHX_ caller_matches);
            PL_runops_boundary_hook = old_hook;
            PL_runops_boundary_data = old_data;
            PL_restartjmpenv = old_restartjmpenv;
            S_generator_free_process_stacks(aTHX_ &generator->process);
        }
    }
    else if (generator->process.context.Itmps_stack) {
        S_generator_free_process_stacks(aTHX_ &generator->process);
    }
    S_generator_free_pads(aTHX_ generator);
    local_bindings_free(generator->local_bindings);
    SvREFCNT_dec(generator->value);
    SvREFCNT_dec((SV *)generator->values);
    SvREFCNT_dec(generator->defsv);
    SvREFCNT_dec((SV *)generator->defav);
    SvREFCNT_dec(generator->errsv);
    SvREFCNT_dec(generator->errorobj);
    SvREFCNT_dec(MUTABLE_SV(generator->environment.rsgv));
    SvREFCNT_dec(generator->environment.irs);
    SvREFCNT_dec(generator->environment.rs);
    SvREFCNT_dec(MUTABLE_SV(generator->environment.hinthv));
    SvREFCNT_dec(MUTABLE_SV(generator->environment.defoutgv));
    cophh_free(generator->environment.hints_hash);
    SvREFCNT_dec(generator->error);
    SvREFCNT_dec((SV *)generator->initial_args);
    SvREFCNT_dec(generator->resume_exception);
    SvREFCNT_dec((SV *)generator->resume_args);
    SvREFCNT_dec((SV *)generator->result);
    SvREFCNT_dec(generator->match_state);
    SvREFCNT_dec(MUTABLE_SV(generator->callsite));
    SvREFCNT_dec((SV *)generator->body);
    Safefree(generator);
    if (cleanup_errors)
        S_generator_defer_cleanup_errors(aTHX_ cleanup_errors);
    if (exiting)
        my_exit_jump();
}

static void
S_generator_pop_stackinfo(pTHX_ PERL_GENERATOR *generator)
{
    PERL_SI * const saved_si = generator->process.context.Icurstackinfo;

    if (!saved_si)
        return;
    PL_curstackinfo = saved_si;
    switch_argstack(saved_si->si_stack);
    /* Unwinding contexts does not release values left on the stack. */
    rpp_obliterate_stack_to(0);
    pop_stackinfo();
    generator->stack_pushed = FALSE;
}

static void
S_generator_detach_stackinfo(pTHX_ PERL_GENERATOR *generator)
{
    PERL_SI * const si = generator->process.context.Icurstackinfo;
    PERL_SI * const prev = si ? si->si_prev : NULL;
    PERL_SI * const next = si ? si->si_next : NULL;

    if (!si || generator->stack_detached)
        return;
    if (prev)
        prev->si_next = next;
    if (next)
        next->si_prev = prev;
    si->si_prev = NULL;
    si->si_next = NULL;
    generator->stack_detached = TRUE;
}

static void
S_generator_attach_stackinfo(pTHX_ PERL_GENERATOR *generator)
{
    PERL_SI * const si = generator->process.context.Icurstackinfo;
    PERL_SI * const prev = PL_curstackinfo;
    PERL_SI * const next = prev ? prev->si_next : NULL;

    if (!si || !generator->stack_detached)
        return;
    si->si_prev = prev;
    si->si_next = next;
    if (next)
        next->si_prev = si;
    if (prev)
        prev->si_next = si;
    generator->stack_detached = FALSE;
}

static void
S_generator_new_stacks(pTHX)
{
    Newx(PL_markstack, 32, Stack_off_t);
    PL_markstack_ptr = PL_markstack;
    PL_markstack_max = PL_markstack + 32;
    Newx(PL_savestack, 32, ANY);
    PL_savestack_ix = 0;
    PL_savestack_max = 32 - SS_MAXPUSH;
    Newx(PL_scopestack, 32, I32);
    PL_scopestack_ix = 0;
    PL_scopestack_max = 32;
#ifdef DEBUGGING
    Newxz(PL_scopestack_name, PL_scopestack_max, const char *);
#endif
    Newx(PL_tmps_stack, 32, SV *);
    PL_tmps_ix = -1;
    PL_tmps_floor = -1;
    PL_tmps_max = 32;
}

typedef struct generator_run {
    PERL_GENERATOR *generator;
    JMPENV *env;
    PERL_SI *stackinfo;
} GENERATOR_RUN;

AV *
Perl_async_multisub_callsite(pTHX_ const PERL_CONTEXT *cx)
{
    GENERATOR_RUN * const run = (GENERATOR_RUN *)PL_runops_boundary_data;
    PERL_GENERATOR *generator;
    I32 i;
    PERL_ARGS_ASSERT_ASYNC_MULTISUB_CALLSITE;
    if (PL_runops_boundary_hook || !cx || CxTYPE(cx) != CXt_SUB
        || !cx->blk_sub.cv || !CvASYNC(cx->blk_sub.cv) || !CvMULTISUB(cx->blk_sub.cv))
        return NULL;
    if (!run || !(generator = run->generator)
        || generator->magic != PERL_GENERATOR_MAGIC || !generator->callsite
        || cx->blk_sub.cv != generator->body
        || !run->stackinfo)
        return NULL;
    /* A synchronous call inside the selected clause keeps its own caller
     * location, including a direct recursive call to the raw body. */
    for (i = 0; i <= run->stackinfo->si_cxix; ++i) {
        PERL_CONTEXT * const frame = &run->stackinfo->si_cxstack[i];
        if (CxTYPE(frame) == CXt_SUB)
            return frame == cx ? generator->callsite : NULL;
    }
    return NULL;
}

static int S_generator_boundary(pTHX_ OP *nextop, void *data);

/* This dispatcher is used only while explicitly driving a suspendable task
 * or a generator adapter. Ordinary opcode dispatch and ordinary generator
 * execution do not test for await. Nested native callbacks enter a different
 * dispatcher, so they cannot inherit this permission. */
static void
S_async_runops(pTHX_ GENERATOR_RUN *run)
{
    OP *op = PL_op;
    PERL_DTRACE_PROBE_OP(op);
    while ((PL_op = op = op->op_type == OP_AWAIT
            ? async_await(run->generator) : op->op_ppaddr(aTHX))) {
        PERL_DTRACE_PROBE_OP(op);
        S_generator_boundary(aTHX_ op, run);
    }
    S_generator_boundary(aTHX_ NULL, run);
}

void
Perl_generator_mark_return(pTHX)
{
    PERL_ARGS_ASSERT_GENERATOR_MARK_RETURN;
    GENERATOR_RUN * const run =
        (GENERATOR_RUN *)PL_runops_boundary_data;
    PERL_GENERATOR * const generator = run ? run->generator : NULL;
    PERL_ARGS_ASSERT_GENERATOR_MARK_RETURN;
    if (!generator || generator->magic != PERL_GENERATOR_MAGIC
        || generator->state != PERL_GENERATOR_RUNNING)
        return;
    generator->explicit_return = TRUE;
}

void
Perl_generator_yield_values(pTHX_ SV **values, SSize_t count)
{
    GENERATOR_RUN * const run =
        (GENERATOR_RUN *)PL_runops_boundary_data;
    PERL_GENERATOR * const generator = run ? run->generator : NULL;

    PERL_ARGS_ASSERT_GENERATOR_YIELD_VALUES;
    if (!generator || generator->magic != PERL_GENERATOR_MAGIC
        || generator->state != PERL_GENERATOR_RUNNING)
        PERL_THROW_ERROR_ITERATOR_GENERATOR_YIELD_WITHOUT_RUNNING_CONTEXT();

    SvREFCNT_dec((SV *)generator->values);
    generator->values = newAV();
    {
        SSize_t i;
        for (i = 0; i < count; i++)
            av_push(generator->values, newSVsv(values[i]));
    }
    SvREFCNT_dec(generator->value);
    generator->value = count ? newSVsv(values[count - 1]) : NULL;
    generator->yield_context = (PL_op->op_flags & OPf_SPECIAL)
        ? G_VOID : GIMME_V;
    generator->yield_pending = TRUE;
}

void
Perl_generator_yield_suspend(pTHX)
{
    GENERATOR_RUN * const run =
        (GENERATOR_RUN *)PL_runops_boundary_data;
    PERL_GENERATOR * const generator = run ? run->generator : NULL;

    PERL_ARGS_ASSERT_GENERATOR_YIELD_SUSPEND;
    if (!generator || generator->magic != PERL_GENERATOR_MAGIC
        || generator->state != PERL_GENERATOR_RUNNING
        || !generator->yield_pending)
        PERL_THROW_ERROR_ITERATOR_GENERATOR_YIELD_WITHOUT_RUNNING_CONTEXT();

    /* Suspending here is safe only from the runops invocation owned by the
     * generator.  A yield reached through a nested runops invocation must
     * first let its active C operation finish; the boundary-aware runloop
     * will suspend it after control returns to the owning stackinfo. */
    if (PL_curstackinfo == run->stackinfo) {
        OP * const nextop = PL_op->op_next;
        PL_op = nextop;
        S_generator_boundary(aTHX_ nextop, run);
    }
}

bool
Perl_generator_is_valid(pTHX_ SV *generator_sv)
{
    PERL_GENERATOR *generator;

    PERL_ARGS_ASSERT_GENERATOR_IS_VALID;
    if (generator_sv && SvROK(generator_sv))
        generator_sv = SvRV(generator_sv);
    if (!generator_sv || SvTYPE(generator_sv) != SVt_PVCV)
        return FALSE;

    generator = (PERL_GENERATOR *)CvXSUBANY((CV *)generator_sv).any_ptr;

    return generator
        && generator->magic == PERL_GENERATOR_MAGIC;
}

bool
Perl_generator_is_exhausted(pTHX_ SV *generator_sv)
{
    PERL_GENERATOR *generator;

    PERL_ARGS_ASSERT_GENERATOR_IS_EXHAUSTED;
    if (!generator_is_valid(generator_sv))
        return FALSE;
    if (generator_sv && SvROK(generator_sv))
        generator_sv = SvRV(generator_sv);

    generator = (PERL_GENERATOR *)CvXSUBANY((CV *)generator_sv).any_ptr;

    return generator
        && (generator->state == PERL_GENERATOR_EXHAUSTED
            || generator->state == PERL_GENERATOR_FAILED);
}

bool
Perl_generator_is_completed(pTHX_ SV *generator_sv)
{
    PERL_GENERATOR *generator;

    PERL_ARGS_ASSERT_GENERATOR_IS_COMPLETED;
    if (!generator_is_valid(generator_sv))
        return FALSE;
    if (generator_sv && SvROK(generator_sv))
        generator_sv = SvRV(generator_sv);

    generator = (PERL_GENERATOR *)CvXSUBANY((CV *)generator_sv).any_ptr;

    return generator
        && generator->magic == PERL_GENERATOR_MAGIC
        && generator->state == PERL_GENERATOR_EXHAUSTED;
}

bool
Perl_generator_is_failed(pTHX_ SV *generator_sv)
{
    PERL_GENERATOR *generator;

    PERL_ARGS_ASSERT_GENERATOR_IS_FAILED;
    if (!generator_is_valid(generator_sv))
        return FALSE;
    if (generator_sv && SvROK(generator_sv))
        generator_sv = SvRV(generator_sv);

    generator = (PERL_GENERATOR *)CvXSUBANY((CV *)generator_sv).any_ptr;

    return generator
        && generator->magic == PERL_GENERATOR_MAGIC
        && generator->state == PERL_GENERATOR_FAILED;
}

bool
Perl_generator_is_running(pTHX_ SV *generator_sv)
{
    PERL_GENERATOR *generator;

    PERL_ARGS_ASSERT_GENERATOR_IS_RUNNING;
    if (!generator_is_valid(generator_sv))
        return FALSE;
    if (generator_sv && SvROK(generator_sv))
        generator_sv = SvRV(generator_sv);

    generator = (PERL_GENERATOR *)CvXSUBANY((CV *)generator_sv).any_ptr;

    return generator
        && generator->magic == PERL_GENERATOR_MAGIC
        && (generator->state == PERL_GENERATOR_NEW
            || generator->state == PERL_GENERATOR_YIELDED);
}

static int
S_generator_boundary(pTHX_ OP *nextop, void *data)
{
    GENERATOR_RUN * const run = (GENERATOR_RUN *)data;
    PERL_GENERATOR * const generator = run->generator;

    /* A class constructor can use another Perl stack for its initializers.
     * Those frames do not belong to this continuation. */
    if (PL_curstackinfo != run->stackinfo)
        return 0;

    if (nextop && !generator->yield_pending)
        return 0;

    if (!nextop) {
        AV *result = newAV();
        SV **svp;
        bool have_defined = FALSE;
        for (svp = PL_stack_base + 1;
             svp <= PL_stack_sp; svp++)
            if (SvOK(*svp)) {
                have_defined = TRUE;
                break;
            }
        if (generator->explicit_return || have_defined) {
            for (svp = PL_stack_base + 1;
                 svp <= PL_stack_sp; svp++)
                av_push(result, newSVsv(*svp));
        }
        SvREFCNT_dec((SV *)generator->result);
        generator->result = result;
    }
    S_generator_park_pads(aTHX_ generator);
    process_state_save(&generator->process);
    generator->captured = TRUE;
    generator->state = nextop && generator->yield_pending
                              ? PERL_GENERATOR_YIELDED
                              : PERL_GENERATOR_EXHAUSTED;
    generator->yield_pending = FALSE;
    S_generator_detach_stackinfo(aTHX_ generator);
    PerlProc_longjmp(run->env->je_buf, 3);
    NOT_REACHED;
}

void
Perl_generator_capture(pTHX_ PERL_GENERATOR *generator, SV *value)
{
    PERL_ARGS_ASSERT_GENERATOR_CAPTURE;
    if (generator->captured
        || (generator->state != PERL_GENERATOR_NEW
            && generator->state != PERL_GENERATOR_RUNNING))
        PERL_THROW_ERROR_ITERATOR_GENERATOR_CONTINUATION_UNAVAILABLE();

    SvREFCNT_dec(generator->value);
    generator->value = value ? newSVsv(value) : NULL;
    process_state_save(&generator->process);
    generator->captured = TRUE;
    generator->state = PERL_GENERATOR_YIELDED;
}

OP *
Perl_async_await(pTHX_ PERL_GENERATOR *owner)
{
    SV *task = sv_mortalcopy(*PL_stack_sp);
    HV *fields;
    SV **state, **value;
    PERL_ARGS_ASSERT_ASYNC_AWAIT;
    if (!SvROK(task) || SvTYPE(SvRV(task)) != SVt_PVHV
        || !sv_derived_from(task, "XPerl::Task") || SvMAGICAL(SvRV(task)))
        PERL_THROW_ERROR_ASYNC_TASK_REQUIRED();
    fields = MUTABLE_HV(SvRV(task));
    state = hv_fetchs(fields, "state", 0);
    if (!state)
        PERL_THROW_ERROR_ASYNC_TASK_REQUIRED();
    if (SvIV(*state) == 2) {
        value = hv_fetchs(fields, "value", 0);
        rpp_replace_1_1_NN(sv_mortalcopy(value ? *value : &PL_sv_undef));
        return PL_op->op_next;
    }
    if (SvIV(*state) == 3) {
        value = hv_fetchs(fields, "error", 0);
        if (!value)
            PERL_THROW_ERROR_ASYNC_TASK_REQUIRED();
        die_unwind(sv_mortalcopy(*value));
    }
    /* Only the owning dispatcher calls this entry with an owner. A nested
     * runloop entered by XS, sort or regex code uses pp_await instead. It
     * cannot leave its native caller suspended, even on the same Perl stack. */
    if (!owner)
        PERL_THROW_ERROR_ASYNC_NATIVE_SUSPENSION_UNSUPPORTED();
    if (!owner->await_allowed)
        PERL_THROW_ERROR_ASYNC_GENERATOR_ADAPTER_REQUIRED();
    generator_yield_values(&task, 1);
    owner->awaiting = TRUE;
    rpp_popfree_1();
    return PL_op->op_next;
}

static void
S_generator_push_resume_result(pTHX_ PERL_GENERATOR *generator)
{
    AV * const args = generator->resume_args;
    const SSize_t count = args ? AvFILLp(args) + 1 : 0;
    SSize_t i;

    if (generator->yield_context == G_SCALAR) {
        rpp_xpush_1(sv_mortalcopy(count ? *av_fetch(args, 0, 0)
                                      : &PL_sv_undef));
    }
    else if (generator->yield_context == G_LIST) {
        for (i = 0; i < count; i++)
            rpp_xpush_1(sv_mortalcopy(*av_fetch(args, i, 0)));
    }
}

int
Perl_generator_resume(pTHX_ PERL_GENERATOR *generator, AV *args)
{
    PERL_PROCESS_STATE caller_state;
    SV *caller_matches;
    runops_boundary_proc_t old_hook = PL_runops_boundary_hook;
    void * const old_data = PL_runops_boundary_data;
    JMPENV * const caller_restartjmpenv = PL_restartjmpenv;
    const bool new_generator = generator->state == PERL_GENERATOR_NEW;
    volatile bool default_variables_swapped = FALSE;
    volatile bool exiting = FALSE;
    AV * volatile exit_errors = NULL;
    GENERATOR_RUN run = { generator, NULL, NULL };
    int ret;
    I32 caller_save;

    PERL_ARGS_ASSERT_GENERATOR_RESUME;
    if (generator->pads_switching)
        PERL_THROW_ERROR_ITERATOR_GENERATOR_CONTINUATION_UNAVAILABLE();
    if (generator->state == PERL_GENERATOR_EXHAUSTED) {
        AV * const old_result = generator->result;
        /* Releasing old values can call this exhausted wrapper again. */
        generator->result = newAV();
        SvREFCNT_dec((SV *)old_result);
        return 0;
    }
    if (generator->state == PERL_GENERATOR_FAILED)
        PERL_THROW_ERROR_ITERATOR_GENERATOR_CANNOT_RESUME_FAILED();
    if (generator->state != PERL_GENERATOR_NEW && !generator->captured)
        PERL_THROW_ERROR_ITERATOR_GENERATOR_NO_SUSPENDED_CONTINUATION();

    caller_save = PL_savestack_ix;
    SAVEBOOL(generator->pads_switching);
    SAVEFREESV(args);
    generator->pads_switching = TRUE;
    if (!local_bindings_validate(generator->local_bindings,
                                &generator->process, generator->environment.rsgv))
        PERL_THROW_ERROR_ITERATOR_GENERATOR_CONTINUATION_UNAVAILABLE();
    if (new_generator) {
        if (generator->initial_args)
            PERL_THROW_ERROR_ITERATOR_GENERATOR_ALREADY_INVOKED();
    }
    else {
        AV *old_args = generator->resume_args;
        generator->resume_args = NULL;
        SvREFCNT_dec((SV *)old_args);
        /* Releasing old arguments can call Perl and change the resumer's
         * aliases. The new arguments stay guarded until validation succeeds. */
        if (!local_bindings_validate(generator->local_bindings,
                                    &generator->process, generator->environment.rsgv))
            PERL_THROW_ERROR_ITERATOR_GENERATOR_CONTINUATION_UNAVAILABLE();
    }
    caller_matches = S_execution_matches_prepare(aTHX_ TRUE);
    if (new_generator)
        generator->initial_args = (AV *)SvREFCNT_inc(args);
    else
        generator->resume_args = (AV *)SvREFCNT_inc(args);
    LEAVE_SCOPE(caller_save);

    S_execution_matches_park(aTHX_ caller_matches);
    process_state_save(&caller_state);
    generator->invoke.op_flags = OPf_STACKED
        | (GIMME_V == G_LIST ? OPf_WANT_LIST
           : GIMME_V == G_VOID ? OPf_WANT_VOID : OPf_WANT_SCALAR);
    generator->captured = FALSE;
    generator->yield_pending = FALSE;
    generator->explicit_return = FALSE;
    generator->awaiting = FALSE;
    generator->state = PERL_GENERATOR_RUNNING;
    if (generator->stack_pushed) {
        if (generator->stack_detached)
            S_generator_attach_stackinfo(aTHX_ generator);
        S_generator_install_pads(aTHX_ generator);
        process_state_restore(&generator->process);
        if (generator->match_state)
            S_execution_matches_restore(aTHX_ generator->match_state);
    }
    /* Native callbacks can run another loop on this same Perl stack. Their
     * return is not completion of the generator. Only its owning loop gets
     * the generator boundary hook. Yield operations use the active data. */
    PL_runops_boundary_hook = NULL;
    PL_runops_boundary_data = &run;

    dJMPENV;
    JMPENV_PUSH(ret);
    /* Rebuild run before callbacks can read it after a longjmp. */
    run.generator = generator;
    run.env = &cur_env;
    run.stackinfo = ret ? PL_curstackinfo : NULL;
    switch (ret) {
    case 0:
        /* This loop owns the exception guard and can restart an eval after
         * a catch. A nested docatch loop would disappear when we yield. */
        cur_env.je_mustcatch = FALSE;
        if (!new_generator) {
            I32 i;
            for (i = 0; i <= cxstack_ix; i++) {
                if (CxTYPE(&cxstack[i]) == CXt_EVAL)
                    cxstack[i].blk_eval.cur_top_env = &cur_env;
            }
        }
        if (new_generator
            && generator->state == PERL_GENERATOR_RUNNING
            && !generator->captured) {
            process_state_capture(&generator->process);
#ifdef PERL_RC_STACK
            push_stackinfo(PERLSI_GENERATOR, 1);
#else
            push_stackinfo(PERLSI_GENERATOR, 0);
#endif
            generator->stack_pushed = TRUE;
            S_generator_new_stacks(aTHX);
            /* The owner is an execution boundary, not a Perl caller frame.
             * Do not save an unowned pointer to the initial caller's pad. */
            PL_comppad = NULL;
            PL_curpad = NULL;
            /* A new execution has no previous match. Inheriting a caller's
             * opcode would leave a dangling pointer if that caller returns
             * while this execution is suspended. */
            PL_curpm = NULL;
            PL_curpm_under = NULL;
            S_generator_swap_environment(aTHX_ generator, TRUE);
            default_variables_swapped = TRUE;
            PL_in_eval = 0;
            PL_restartop = NULL;
            PUSHMARK(PL_stack_sp);
            create_eval_scope(NULL, PL_stack_sp, G_FAKINGEVAL);
            generator->eval_active = TRUE;
            {
                I32 i;
                for (i = 0; generator->initial_args
                        && i <= AvFILLp(generator->initial_args); i++)
                    rpp_xpush_1(*av_fetch(generator->initial_args, i, 0));
            }
            rpp_xpush_1(MUTABLE_SV(generator->body));
            PL_op = (OP *)&generator->invoke;
        }
        else {
            I32 i;
            for (i = 0; i <= cxstack_ix; i++) {
                if (CxTYPE(&cxstack[i]) == CXt_EVAL)
                    cxstack[i].blk_eval.cur_top_env = &cur_env;
            }
            S_generator_swap_environment(aTHX_ generator, TRUE);
            default_variables_swapped = TRUE;
            local_bindings_resume(generator->local_bindings, PL_savestack);
            if (generator->resume_exception) {
                SV * const error = generator->resume_exception;
                generator->resume_exception = NULL;
                die_unwind(sv_2mortal(error));
            }
            S_generator_push_resume_result(aTHX_ generator);
        }
    run_execution:
        run.stackinfo = PL_curstackinfo;
        if (generator->await_allowed)
            S_async_runops(aTHX_ &run);
        else
            S_runops_with_hook(aTHX_ S_generator_boundary, &run);
        break;
    case 2:
        exiting = TRUE;
    unwind_exit:
        generator->eval_active = FALSE;
        generator->captured = FALSE;
        generator->yield_pending = FALSE;
        generator->state = PERL_GENERATOR_EXHAUSTED;
        PL_runops_boundary_hook = NULL;
        PL_runops_boundary_data = NULL;
        S_generator_unwind(aTHX_ generator, &cur_env);
        S_generator_pop_stackinfo(aTHX_ generator);
        S_generator_restore_pads(aTHX_ generator);
        JMPENV_POP;
        if (default_variables_swapped)
            S_generator_swap_environment(aTHX_ generator, FALSE);
        process_state_restore(&caller_state);
        S_execution_matches_restore(aTHX_ caller_matches);
        PL_runops_boundary_hook = old_hook;
        PL_runops_boundary_data = old_data;
        PL_restartjmpenv = caller_restartjmpenv;
        S_generator_free_process_stacks(aTHX_ &generator->process);
        S_generator_free_pads(aTHX_ generator);
        local_bindings_free(generator->local_bindings);
        generator->local_bindings = NULL;
        {
            const I32 floor = PL_savestack_ix;
            AV * const release = newAV();
            SAVEFREESV(release);
            /* The wrapper may survive into END. Release its execution now,
             * even if the caller keeps a reference to that terminal wrapper. */
#define RELEASE_FIELD(field) STMT_START {              \
    if (generator->field) {                            \
        av_push(release, MUTABLE_SV(generator->field)); \
        generator->field = NULL;                       \
    }                                                 \
} STMT_END
            RELEASE_FIELD(initial_args);
            RELEASE_FIELD(resume_args);
            RELEASE_FIELD(values);
            RELEASE_FIELD(value);
            RELEASE_FIELD(result);
            RELEASE_FIELD(defsv);
            RELEASE_FIELD(defav);
            RELEASE_FIELD(errsv);
            RELEASE_FIELD(errorobj);
            RELEASE_FIELD(environment.rsgv);
            RELEASE_FIELD(environment.irs);
            RELEASE_FIELD(environment.rs);
            RELEASE_FIELD(environment.hinthv);
            RELEASE_FIELD(environment.defoutgv);
            cophh_free(generator->environment.hints_hash);
            generator->environment.hints_hash = NULL;
            RELEASE_FIELD(error);
            RELEASE_FIELD(resume_exception);
            RELEASE_FIELD(match_state);
            RELEASE_FIELD(callsite);
            RELEASE_FIELD(body);
#undef RELEASE_FIELD
            LEAVE_SCOPE(floor);
        }
        if (exit_errors)
            S_generator_defer_cleanup_errors(aTHX_ exit_errors);
        my_exit_jump();
        NOT_REACHED;
    default:
        if (exiting && ret == 3) {
            SV * const error = SvROK(PERL_ERROR_OBJ) ? PERL_ERROR_OBJ : ERRSV;
            if (!exit_errors)
                exit_errors = newAV();
            av_push(exit_errors, newSVsv(error));
            goto unwind_exit;
        }
        if (generator->captured)
            break;
        if (ret == 3 && PL_restartjmpenv == PL_top_env && PL_restartop) {
            /* A failed park is a caught exception, not a completed yield.
             * Do not hand its packet to the caller at the next boundary. */
            if (generator->yield_pending) {
                SV * const value = generator->value;
                AV * const values = generator->values;
                generator->yield_pending = FALSE;
                generator->value = NULL;
                generator->awaiting = FALSE;
                generator->values = NULL;
                if (value)
                    sv_2mortal(value);
                if (values)
                    sv_2mortal(MUTABLE_SV(values));
            }
            PL_op = PL_restartop;
            PL_restartop = NULL;
            PL_restartjmpenv = NULL;
            goto run_execution;
        }
        generator->state = PERL_GENERATOR_FAILED;
        generator->eval_active = FALSE;
        SvREFCNT_dec(generator->error);
        generator->error = newSVsv(SvROK(PERL_ERROR_OBJ) ? PERL_ERROR_OBJ : ERRSV);
        if (generator->stack_pushed && cxstack_ix >= 0)
            dounwind(-1);
        if (generator->stack_pushed) {
            /* A new generator may fail before reaching a runops boundary,
             * so its private stack pointers have not yet been copied into
             * its saved process state. */
            process_state_save(&generator->process);
            S_generator_pop_stackinfo(aTHX_ generator);
        }
        S_generator_restore_pads(aTHX_ generator);
        JMPENV_POP;
        PL_runops_boundary_hook = old_hook;
        PL_runops_boundary_data = old_data;
        if (default_variables_swapped)
            S_generator_swap_environment(aTHX_ generator, FALSE);
        process_state_restore(&caller_state);
        S_execution_matches_restore(aTHX_ caller_matches);
        S_generator_free_pads(aTHX_ generator);
        PL_restartjmpenv = PL_top_env;
        {
            SV * const error = generator->error;
            generator->error = NULL;
            die_unwind(sv_2mortal(error));
        }
        NOT_REACHED;
    }
    JMPENV_POP;

    PL_runops_boundary_hook = old_hook;
    PL_runops_boundary_data = old_data;
    if (generator->state == PERL_GENERATOR_EXHAUSTED) {
        if (generator->eval_active) {
            process_state_restore(&generator->process);
            dounwind(-1);
            process_state_save(&generator->process);
            generator->eval_active = FALSE;
        }
        process_state_restore(&caller_state);
        S_generator_attach_stackinfo(aTHX_ generator);
        process_state_restore(&generator->process);
        S_generator_pop_stackinfo(aTHX_ generator);
        generator->captured = FALSE;
    }
    if (default_variables_swapped)
        S_generator_swap_environment(aTHX_ generator, FALSE);
    process_state_restore(&caller_state);
    S_execution_matches_restore(aTHX_ caller_matches);
    PL_restartjmpenv = caller_restartjmpenv;
    return generator->state == PERL_GENERATOR_YIELDED ? 1 : 0;
}

static int
S_runops_with_boundary(pTHX)
{
    return S_runops_with_hook(aTHX_ PL_runops_boundary_hook,
                             PL_runops_boundary_data);
}

static int
S_runops_with_hook(pTHX_ runops_boundary_proc_t hook, void *data)
{
    OP *op = PL_op;
    PERL_DTRACE_PROBE_OP(op);
    while ((PL_op = op = op->op_ppaddr(aTHX))) {
        PERL_DTRACE_PROBE_OP(op);
        if (hook && hook(aTHX_ op, data))
            return PERL_RUNOPS_BOUNDARY_YIELD;
    }
    if (hook && hook(aTHX_ NULL, data))
        return PERL_RUNOPS_BOUNDARY_YIELD;
    PERL_ASYNC_CHECK();

    TAINT_NOT;
    return 0;
}

int
Perl_runops_standard(pTHX)
{
    OP *op;

    PERL_ARGS_ASSERT_RUNOPS_STANDARD;

    op = PL_op;
    PERL_DTRACE_PROBE_OP(op);
    while ((PL_op = op = op->op_ppaddr(aTHX)))
        PERL_DTRACE_PROBE_OP(op);
    PERL_ASYNC_CHECK();

    TAINT_NOT;
    return 0;
}


#ifdef PERL_RC_STACK

/* this is a wrapper for all runops-style functions. It temporarily
 * reifies the stack if necessary, then calls the real runops function
 */
int
Perl_runops_wrap(pTHX)
{
    PERL_ARGS_ASSERT_RUNOPS_WRAP;

    /* runops loops assume a ref-counted stack. If we have been called via a
     * wrapper (pp_wrap or xs_wrap) with the top half of the stack not
     * reference-counted, or with a non-real stack, temporarily convert it
     * to reference-counted. This is because the si_stack_nonrc_base
     * mechanism only allows a single split in the stack, not multiple
     * stripes.
     * At the end, we revert the stack (or part thereof) to non-refcounted
     * to keep whoever our caller is happy.
     *
     * If what we call croaks, catch it, revert, then rethrow.
     */

    I32 cut;          /* the cut point between refcnted and non-refcnted */
    bool was_real  = cBOOL(AvREAL(PL_curstack));
    I32  old_base  = PL_curstackinfo->si_stack_nonrc_base;

    if (was_real && !old_base) {
        PL_runops(aTHX); /* call the real loop */
        return 0;
    }

    if (was_real) {
        cut = old_base;
        assert(PL_stack_base + cut <= PL_stack_sp + 1);
        PL_curstackinfo->si_stack_nonrc_base = 0;
    }
    else {
        assert(!old_base);
        assert(!AvREIFY(PL_curstack));
        AvREAL_on(PL_curstack);
        /* skip the PL_sv_undef guard at PL_stack_base[0] but still
         * signal adjusting may be needed on return by setting to a
         * non-zero value - even if stack is empty */
        cut = 1;
    }

    if (cut) {
        SV **svp = PL_stack_base + cut;
        while (svp <= PL_stack_sp) {
            SvREFCNT_inc_simple_void(*svp);
            svp++;
        }
    }

    AV * old_curstack = PL_curstack;

    /* run the real loop while catching exceptions */
    dJMPENV;
    int ret;
    JMPENV_PUSH(ret);
    switch (ret) {
    case 0: /* normal return from JMPENV_PUSH */
        cur_env.je_mustcatch = cur_env.je_prev->je_mustcatch;
        PL_runops(aTHX); /* call the real loop */

      revert:
        /* revert stack back its non-ref-counted state */
        assert(AvREAL(PL_curstack));

        if (cut) {
            /* undo the stack reification that took place at the beginning of
             * this function */
            if (UNLIKELY(!was_real))
                AvREAL_off(PL_curstack);

            SSize_t n = PL_stack_sp - (PL_stack_base + cut) + 1;
            if (n > 0) {
                /* we need to decrement the refcount of every SV from cut
                 * upwards; but this may prematurely free them, so
                 * mortalise them instead */
                EXTEND_MORTAL(n);
                for (SSize_t i = 0; i < n; i ++) {
                    SV* sv = PL_stack_base[cut + i];
                    if (sv)
                        PL_tmps_stack[++PL_tmps_ix] = sv;
                }
            }

            I32 sp1 = PL_stack_sp - PL_stack_base + 1;
            PL_curstackinfo->si_stack_nonrc_base =
                                old_base > sp1 ? sp1 : old_base;
        }
        break;

    case 3: /* exception trapped by eval - stack only partially unwound */

        /* if the exception has already unwound to before the current
         * stack, no need to fix it up */
        if (old_curstack == PL_curstack)
            goto revert;
        break;

    default:
        break;
    }

    JMPENV_POP;

    if (ret) {
        JMPENV_JUMP(ret); /* re-throw the exception */
        NOT_REACHED; /* NOTREACHED */
    }

    return 0;
}

#endif

/*
 * ex: set ts=8 sts=4 sw=4 et:
 */
