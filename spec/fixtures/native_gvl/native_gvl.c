#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <time.h>
#include <ruby.h>
#include <ruby/thread.h>

#define MAX_SLEEP_MILLISECONDS 10000UL

static unsigned long
sleep_duration(VALUE value)
{
  unsigned long milliseconds = NUM2ULONG(value);

  if (milliseconds == 0 || milliseconds > MAX_SLEEP_MILLISECONDS) {
    rb_raise(rb_eArgError, "milliseconds must be in 1..10000");
  }

  return milliseconds;
}

static void
sleep_milliseconds(unsigned long milliseconds)
{
  struct timespec remaining;

  remaining.tv_sec = (time_t)(milliseconds / 1000UL);
  remaining.tv_nsec = (long)((milliseconds % 1000UL) * 1000000UL);
  while (nanosleep(&remaining, &remaining) == -1 && errno == EINTR) {
  }
}

static void *
sleep_without_gvl(void *argument)
{
  sleep_milliseconds(*(unsigned long *)argument);
  return NULL;
}

static VALUE
native_hold_gvl(VALUE self, VALUE milliseconds_value)
{
  unsigned long milliseconds = sleep_duration(milliseconds_value);
  (void)self;
  sleep_milliseconds(milliseconds);
  return Qnil;
}

static VALUE
native_release_gvl(VALUE self, VALUE milliseconds_value)
{
  unsigned long milliseconds = sleep_duration(milliseconds_value);
  (void)self;
  rb_thread_call_without_gvl(sleep_without_gvl, &milliseconds, RUBY_UBF_IO, NULL);
  return Qnil;
}

void
Init_fiber_audit_native_gvl(void)
{
  VALUE fixture = rb_define_module("FiberAuditNativeGVL");
  rb_define_singleton_method(fixture, "hold_gvl", native_hold_gvl, 1);
  rb_define_singleton_method(fixture, "release_gvl", native_release_gvl, 1);
}
