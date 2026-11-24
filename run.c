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

static MGVTBL S_iter_adapter_magic = { 0, 0, 0, 0, 0, 0, 0, 0 };

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

    PERL_ARGS_ASSERT_GENERATOR_NEW;
    Newxz(generator, 1, PERL_GENERATOR);
    generator->magic = PERL_GENERATOR_MAGIC;
    generator->body = (CV *)SvREFCNT_inc_simple((SV *)body);
    generator->defsv = newSVsv(GvSV(PL_defgv)
                               ? GvSV(PL_defgv) : &PL_sv_undef);
    generator->defav = newAV();
    generator->errsv = newSV(0);
    generator->errorobj = newSV(0);
    generator->invoke.op_ppaddr = PL_ppaddr[OP_ENTERSUB];
    generator->invoke.op_type = OP_ENTERSUB;
    generator->invoke.op_flags = OPf_STACKED | OPf_WANT_SCALAR;
    generator->state = PERL_GENERATOR_NEW;
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

    PERL_UNUSED_ARG(cv);
    if (!generator || generator->magic != PERL_GENERATOR_MAGIC)
        PERL_THROW_ERROR_ITERATOR_GENERATOR_INVALID_WRAPPER();
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
S_generator_swap_default_variables(pTHX_ PERL_GENERATOR *generator)
{
    SV * const defsv = GvSV(PL_defgv);
    AV * const defav = GvAV(PL_defgv);
    SV * const errsv = ERRSV;
    SV * const errorobj = PERL_ERROR_OBJ;

    /* Exchange bindings so references and argument aliases keep their SVs. */
    GvSV(PL_defgv) = generator->defsv;
    generator->defsv = defsv;
    GvAV(PL_defgv) = generator->defav;
    generator->defav = defav;
    GvSV(PL_errgv) = generator->errsv;
    generator->errsv = errsv;
    GvSV(PL_errorobjgv) = generator->errorobj;
    generator->errorobj = errorobj;
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
    SAVEDESTRUCTOR_X(S_generator_warn_cleanup, INT2PTR(void *, index));
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

            process_state_save(&caller_state);
            if (generator->stack_detached)
                S_generator_attach_stackinfo(aTHX_ generator);
            S_generator_install_pads(aTHX_ generator);
            process_state_restore(&generator->process);
            /* Scope cleanup can run Perl destructors. They belong to the
             * abandoned execution, including its default variables. */
            S_generator_swap_default_variables(aTHX_ generator);
            PL_runops_boundary_hook = NULL;
            PL_runops_boundary_data = NULL;
            JMPENV_PUSH(ret);
            if (ret == 2)
                exiting = TRUE;
            if (ret && ret != 2 && ret != 3) {
                process_state_save(&generator->process);
                JMPENV_POP;
                S_generator_restore_pads(aTHX_ generator);
                S_generator_swap_default_variables(aTHX_ generator);
                process_state_restore(&caller_state);
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
            S_generator_swap_default_variables(aTHX_ generator);
            process_state_restore(&caller_state);
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
    SvREFCNT_dec(generator->value);
    SvREFCNT_dec((SV *)generator->values);
    SvREFCNT_dec(generator->defsv);
    SvREFCNT_dec((SV *)generator->defav);
    SvREFCNT_dec(generator->errsv);
    SvREFCNT_dec(generator->errorobj);
    SvREFCNT_dec(generator->error);
    SvREFCNT_dec((SV *)generator->initial_args);
    SvREFCNT_dec((SV *)generator->resume_args);
    SvREFCNT_dec((SV *)generator->result);
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

static int S_generator_boundary(pTHX_ OP *nextop, void *data);

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
    runops_boundary_proc_t old_hook = PL_runops_boundary_hook;
    void * const old_data = PL_runops_boundary_data;
    JMPENV * const caller_restartjmpenv = PL_restartjmpenv;
    const bool new_generator = generator->state == PERL_GENERATOR_NEW;
    volatile bool default_variables_swapped = FALSE;
    volatile bool exiting = FALSE;
    AV * volatile exit_errors = NULL;
    GENERATOR_RUN run = { generator, NULL, NULL };
    int ret;

    PERL_ARGS_ASSERT_GENERATOR_RESUME;
    if (generator->state == PERL_GENERATOR_EXHAUSTED) {
        SvREFCNT_dec((SV *)generator->result);
        generator->result = newAV();
        return 0;
    }
    if (generator->state == PERL_GENERATOR_FAILED)
        PERL_THROW_ERROR_ITERATOR_GENERATOR_CANNOT_RESUME_FAILED();
    if (generator->state != PERL_GENERATOR_NEW && !generator->captured)
        PERL_THROW_ERROR_ITERATOR_GENERATOR_NO_SUSPENDED_CONTINUATION();

    if (new_generator) {
        if (generator->initial_args)
            PERL_THROW_ERROR_ITERATOR_GENERATOR_ALREADY_INVOKED();
        generator->initial_args = args;
    }
    else {
        SvREFCNT_dec((SV *)generator->resume_args);
        generator->resume_args = args;
    }

    process_state_save(&caller_state);
    generator->invoke.op_flags = OPf_STACKED
        | (GIMME_V == G_LIST ? OPf_WANT_LIST
           : GIMME_V == G_VOID ? OPf_WANT_VOID : OPf_WANT_SCALAR);
    generator->captured = FALSE;
    generator->yield_pending = FALSE;
    generator->explicit_return = FALSE;
    generator->state = PERL_GENERATOR_RUNNING;
    if (generator->stack_pushed) {
        if (generator->stack_detached)
            S_generator_attach_stackinfo(aTHX_ generator);
        S_generator_install_pads(aTHX_ generator);
        process_state_restore(&generator->process);
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
            S_generator_swap_default_variables(aTHX_ generator);
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
            /* Argument magic may throw and unwind private scopes. Install
             * the owner's defaults before running that code. */
            S_generator_swap_default_variables(aTHX_ generator);
            default_variables_swapped = TRUE;
            S_generator_push_resume_result(aTHX_ generator);
        }
    run_execution:
        run.stackinfo = PL_curstackinfo;
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
            S_generator_swap_default_variables(aTHX_ generator);
        process_state_restore(&caller_state);
        PL_runops_boundary_hook = old_hook;
        PL_runops_boundary_data = old_data;
        PL_restartjmpenv = caller_restartjmpenv;
        S_generator_free_process_stacks(aTHX_ &generator->process);
        S_generator_free_pads(aTHX_ generator);
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
            RELEASE_FIELD(error);
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
            S_generator_swap_default_variables(aTHX_ generator);
        process_state_restore(&caller_state);
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
        S_generator_swap_default_variables(aTHX_ generator);
    process_state_restore(&caller_state);
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
