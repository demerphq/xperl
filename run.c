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

void
Perl_process_state_save(pTHX_ PERL_PROCESS_STATE *state)
{
    PERL_ARGS_ASSERT_PROCESS_STATE_SAVE;

    state->op = PL_op;
    state->curcop = PL_curcop;
    state->comppad = PL_comppad;
    state->curpad = PL_curpad;
    state->curstack = PL_curstack;
    state->curstackinfo = PL_curstackinfo;
    state->stack_base = PL_stack_base;
    state->stack_max = PL_stack_max;
    state->stack_sp = PL_stack_sp;
    state->curpm = PL_curpm;
    state->curpm_under = PL_curpm_under;
    state->reg_curpm = PL_reg_curpm;
    state->multideref_pc = PL_multideref_pc;
    state->defgv = PL_defgv;
    state->curstash = PL_curstash;
    state->curcopdb = PL_curcopdb;
    state->tainting = PL_tainting;
    state->tainted = PL_tainted;
    state->delaymagic = PL_delaymagic;
    state->dowarn = PL_dowarn;
    state->markstack = PL_markstack;
    state->markstack_ptr = PL_markstack_ptr;
    state->markstack_max = PL_markstack_max;
    state->savestack = PL_savestack;
    state->savestack_ix = PL_savestack_ix;
    state->savestack_max = PL_savestack_max;
    state->scopestack = PL_scopestack;
    state->scopestack_ix = PL_scopestack_ix;
    state->scopestack_max = PL_scopestack_max;
    state->tmps_stack = PL_tmps_stack;
    state->tmps_ix = PL_tmps_ix;
    state->tmps_floor = PL_tmps_floor;
    state->tmps_max = PL_tmps_max;
    state->in_eval = PL_in_eval;
    state->localizing = PL_localizing;
    state->restartop = PL_restartop;
}

void
Perl_process_state_restore(pTHX_ const PERL_PROCESS_STATE *state)
{
    PERL_ARGS_ASSERT_PROCESS_STATE_RESTORE;

    PL_op = state->op;
    PL_curcop = state->curcop;
    PL_comppad = state->comppad;
    PL_curpad = state->curpad;
    PL_curstack = state->curstack;
    PL_curstackinfo = state->curstackinfo;
    PL_stack_base = state->stack_base;
    PL_stack_max = state->stack_max;
    PL_stack_sp = state->stack_sp;
    PL_curpm = state->curpm;
    PL_curpm_under = state->curpm_under;
    PL_reg_curpm = state->reg_curpm;
    PL_multideref_pc = state->multideref_pc;
    PL_defgv = state->defgv;
    PL_curstash = state->curstash;
    PL_curcopdb = state->curcopdb;
    PL_tainting = state->tainting;
    PL_tainted = state->tainted;
    PL_delaymagic = state->delaymagic;
    PL_dowarn = state->dowarn;
    PL_markstack = state->markstack;
    PL_markstack_ptr = state->markstack_ptr;
    PL_markstack_max = state->markstack_max;
    PL_savestack = state->savestack;
    PL_savestack_ix = state->savestack_ix;
    PL_savestack_max = state->savestack_max;
    PL_scopestack = state->scopestack;
    PL_scopestack_ix = state->scopestack_ix;
    PL_scopestack_max = state->scopestack_max;
    PL_tmps_stack = state->tmps_stack;
    PL_tmps_ix = state->tmps_ix;
    PL_tmps_floor = state->tmps_floor;
    PL_tmps_max = state->tmps_max;
    PL_in_eval = state->in_eval;
    PL_localizing = state->localizing;
    PL_restartop = state->restartop;
}

static int
S_process_scheduler_boundary(pTHX_ OP *nextop, void *data)
{
    PERL_PROCESS_SCHEDULER * const scheduler = (PERL_PROCESS_SCHEDULER *)data;

    process_state_save(&scheduler->states[scheduler->current]);

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
    PERL_UNUSED_ARG(sv);
    if (generator) {
        generator_free(generator);
        mg->mg_ptr = NULL;
    }
    return 0;
}

static MGVTBL S_generator_magic = {
    0, 0, 0, 0, S_generator_magic_free,
    0, 0, 0
};

static void
S_generator_xsub(pTHX_ CV *cv)
{
    dXSARGS;
    PERL_GENERATOR * const generator =
        (PERL_GENERATOR *)XSANY.any_ptr;

    PERL_UNUSED_ARG(cv);
    if (items)
        croak("generator does not accept arguments");
    if (!generator || generator->magic != PERL_GENERATOR_MAGIC)
        croak("invalid generator");
    if (!generator_resume(generator))
        XSRETURN_EMPTY;
    EXTEND(SP, 1);
    ST(0) = newSVsv(generator->value);
    XSRETURN(1);
}

CV *
Perl_generator_wrap(pTHX_ CV *body)
{
    CV *wrapper;
    PERL_GENERATOR *generator;

    PERL_ARGS_ASSERT_GENERATOR_WRAP;
    generator = generator_new(body);
    wrapper = newXS_flags(NULL, S_generator_xsub, __FILE__, NULL, 0);
    CvXSUBANY(wrapper).any_ptr = generator;
    sv_magicext(MUTABLE_SV(wrapper), NULL, PERL_MAGIC_ext,
                &S_generator_magic, (char *)generator, 0);
    return wrapper;
}

static void S_generator_pop_stackinfo(pTHX_ PERL_GENERATOR *generator);
static void S_generator_detach_stackinfo(pTHX_ PERL_GENERATOR *generator);
static void S_generator_attach_stackinfo(pTHX_ PERL_GENERATOR *generator);

static void
S_generator_free_tmps(pTHX_ PERL_PROCESS_STATE *process)
{
    while (process->tmps_ix >= 0) {
        SV * const sv = process->tmps_stack[process->tmps_ix--];
        if (sv) {
            SvTEMP_off(sv);
            SvREFCNT_dec_NN(sv);
        }
    }
}

static void
S_generator_free_process_stacks(pTHX_ PERL_PROCESS_STATE *process)
{
    S_generator_free_tmps(aTHX_ process);
    Safefree(process->markstack);
    Safefree(process->savestack);
    Safefree(process->scopestack);
    Safefree(process->tmps_stack);
    process->markstack = NULL;
    process->savestack = NULL;
    process->scopestack = NULL;
    process->tmps_stack = NULL;
}

void
Perl_generator_free(pTHX_ PERL_GENERATOR *generator)
{
    PERL_PROCESS_STATE caller_state;

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
            process_state_save(&caller_state);
            if (generator->stack_detached)
                S_generator_attach_stackinfo(aTHX_ generator);
            process_state_restore(&generator->process);
            if (generator->eval_active)
                dounwind(-1);
            generator->eval_active = FALSE;
            S_generator_pop_stackinfo(aTHX_ generator);
            S_generator_free_process_stacks(aTHX_ &generator->process);
            process_state_restore(&caller_state);
        }
    }
    else if (generator->process.tmps_stack) {
        S_generator_free_process_stacks(aTHX_ &generator->process);
    }
    SvREFCNT_dec(generator->value);
    SvREFCNT_dec(generator->error);
    SvREFCNT_dec((SV *)generator->body);
    Safefree(generator);
}

static void
S_generator_pop_stackinfo(pTHX_ PERL_GENERATOR *generator)
{
    PERL_SI * const saved_si = generator->process.curstackinfo;

    if (!saved_si)
        return;
    PL_curstackinfo = saved_si;
    switch_argstack(saved_si->si_stack);
    pop_stackinfo();
    generator->stack_pushed = FALSE;
}

static void
S_generator_detach_stackinfo(pTHX_ PERL_GENERATOR *generator)
{
    PERL_SI * const si = generator->process.curstackinfo;
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
    PERL_SI * const si = generator->process.curstackinfo;
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
    Newx(PL_tmps_stack, 32, SV *);
    PL_tmps_ix = -1;
    PL_tmps_floor = -1;
    PL_tmps_max = 32;
}

typedef struct generator_run {
    PERL_GENERATOR *generator;
    JMPENV *env;
} GENERATOR_RUN;

void
Perl_generator_yield_value(pTHX_ SV *value)
{
    GENERATOR_RUN * const run =
        (GENERATOR_RUN *)PL_runops_boundary_data;
    PERL_GENERATOR * const generator = run ? run->generator : NULL;

    PERL_ARGS_ASSERT_GENERATOR_YIELD_VALUE;
    if (!generator || generator->magic != PERL_GENERATOR_MAGIC
        || generator->state != PERL_GENERATOR_RUNNING)
        croak("generator_yield outside a running generator_create");

    SvREFCNT_dec(generator->value);
    generator->value = newSVsv(value);
    generator->yield_pending = TRUE;
}

bool
Perl_generator_is_exhausted(pTHX_ SV *generator_sv)
{
    PERL_GENERATOR *generator;

    PERL_ARGS_ASSERT_GENERATOR_IS_EXHAUSTED;
    if (generator_sv && SvROK(generator_sv))
        generator_sv = SvRV(generator_sv);
    if (!generator_sv || SvTYPE(generator_sv) != SVt_PVCV)
        return FALSE;

    generator = (PERL_GENERATOR *)CvXSUBANY((CV *)generator_sv).any_ptr;

    return generator
        && generator->magic == PERL_GENERATOR_MAGIC
        && generator->state == PERL_GENERATOR_EXHAUSTED;
}

static int
S_generator_boundary(pTHX_ OP *nextop, void *data)
{
    GENERATOR_RUN * const run = (GENERATOR_RUN *)data;
    PERL_GENERATOR * const generator = run->generator;

    if (nextop && !generator->yield_pending)
        return 0;

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
        croak("generator continuation is not available");

    SvREFCNT_dec(generator->value);
    generator->value = value ? newSVsv(value) : NULL;
    process_state_save(&generator->process);
    generator->captured = TRUE;
    generator->state = PERL_GENERATOR_YIELDED;
}

int
Perl_generator_resume(pTHX_ PERL_GENERATOR *generator)
{
    PERL_PROCESS_STATE caller_state;
    runops_boundary_proc_t old_hook = PL_runops_boundary_hook;
    void * const old_data = PL_runops_boundary_data;
    JMPENV * const caller_restartjmpenv = PL_restartjmpenv;
    const bool new_generator = generator->state == PERL_GENERATOR_NEW;
    GENERATOR_RUN run = { generator, NULL };
    int ret;

    PERL_ARGS_ASSERT_GENERATOR_RESUME;
    if (generator->state == PERL_GENERATOR_EXHAUSTED)
        croak("cannot resume an exhausted generator");
    if (generator->state == PERL_GENERATOR_FAILED)
        croak("cannot resume a failed generator");
    if (generator->state != PERL_GENERATOR_NEW && !generator->captured)
        croak("generator has no suspended continuation");

    process_state_save(&caller_state);
    generator->invoke.op_flags = OPf_STACKED
        | (GIMME_V == G_LIST ? OPf_WANT_LIST
           : GIMME_V == G_VOID ? OPf_WANT_VOID : OPf_WANT_SCALAR);
    generator->captured = FALSE;
    generator->yield_pending = FALSE;
    generator->state = PERL_GENERATOR_RUNNING;
    if (generator->stack_pushed) {
        if (generator->stack_detached)
            S_generator_attach_stackinfo(aTHX_ generator);
        process_state_restore(&generator->process);
    }
    PL_runops_boundary_hook = S_generator_boundary;
    PL_runops_boundary_data = &run;

    dJMPENV;
    JMPENV_PUSH(ret);
    switch (ret) {
    case 0:
        cur_env.je_mustcatch = TRUE;
        run.env = &cur_env;
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
            push_stackinfo(PERLSI_UNKNOWN, 0);
            generator->stack_pushed = TRUE;
            S_generator_new_stacks(aTHX);
            PL_in_eval = 0;
            PL_restartop = NULL;
            process_state_save(&generator->process);
            PUSHMARK(PL_stack_sp);
            create_eval_scope(NULL, PL_stack_sp, G_FAKINGEVAL);
            generator->eval_active = TRUE;
            rpp_xpush_1(MUTABLE_SV(generator->body));
            PL_op = (OP *)&generator->invoke;
            PL_runops(aTHX);
        }
        else {
            I32 i;
            for (i = 0; i <= cxstack_ix; i++) {
                if (CxTYPE(&cxstack[i]) == CXt_EVAL)
                    cxstack[i].blk_eval.cur_top_env = &cur_env;
            }
            PL_runops(aTHX);
        }
        break;
    default:
        if (generator->captured)
            break;
        generator->state = PERL_GENERATOR_FAILED;
        generator->eval_active = FALSE;
        SvREFCNT_dec(generator->error);
        generator->error = newSVsv(ERRSV);
        if (generator->stack_pushed && cxstack_ix >= 0)
            dounwind(-1);
        if (generator->stack_pushed)
            S_generator_pop_stackinfo(aTHX_ generator);
        JMPENV_POP;
        PL_runops_boundary_hook = old_hook;
        PL_runops_boundary_data = old_data;
        process_state_restore(&caller_state);
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
    process_state_restore(&caller_state);
    PL_restartjmpenv = caller_restartjmpenv;
    return generator->state == PERL_GENERATOR_YIELDED ? 1 : 0;
}

int
Perl_runops_standard(pTHX)
{
    PERL_ARGS_ASSERT_RUNOPS_STANDARD;

    OP *op = PL_op;
    PERL_DTRACE_PROBE_OP(op);
    while ((PL_op = op = op->op_ppaddr(aTHX))) {
        PERL_DTRACE_PROBE_OP(op);
        if (PL_runops_boundary_hook
            && PL_runops_boundary_hook(aTHX_ op, PL_runops_boundary_data))
            return PERL_RUNOPS_BOUNDARY_YIELD;
    }
    if (PL_runops_boundary_hook
        && PL_runops_boundary_hook(aTHX_ NULL, PL_runops_boundary_data))
        return PERL_RUNOPS_BOUNDARY_YIELD;
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
