# Continuation graph structure
# Represents code in a form much like CPS, but with degrees of freedom to
# encode partial ordering. Specifically:
#
# (+ (f x) (g y))
# CPS -> (λk (f x
#          (λfx (g y
#            (λgy (+ fx gy k))))))
#
# In our continuation graph structure, we replace the fixed evaluation order
# with a (co*) form that provides parallelism:
#
# (+ (f x) (g y))
# -> (λk (co* (λk1 (f x k1))
#             (λk2 (g y k2))
#             (λ[fx gy]
#               (+ fx gy k))))
#
# Semantically, (co*) returns once all of the sub-continuations are invoked,
# and additionally when any of the sub-continuations is re-invoked. So:
#
# > (co* (λk1 ...)
#        (λk2 ...)
#        (λk3 ...)
#        (λ[v1 v2 v3] (print v1 v2 v3)))
# > (k1 5)              # nothing happens
# > (k2 6)              # nothing happens
# > (k1 7)              # nothing happens
# > (k3 9)              # (print 5 6 9) (print 7 6 9)
# > (k2 4)              # (print 7 4 9)
#
# Non-triggering continuations are required to hold only a weak reference to
# the other continuation queues. That way if k3 is freed before being called,
# k1 and k2's space usage will be constant even if they are called repeatedly
# (which would normally enqueue stuff).
#
# NB: the order of arguments relative to one another is explicitly undefined;
# that is, if we have (k1 4) (k1 5) (k1 6) and (k2 a) (k2 b), the (co*)
# continuation might see [4 a] [5 a] [6 a] or it might see [4 a] [4 b] [5 b],
# etc. The queues of k1 and k2 are mutually unordered.
#
# Along with (co*) is (amb*), which forwards only the first continuation. That
# is:
#
# > (amb* (λk1 ...)
#         (λk2 ...)
#         (λv (print v)))
# > (k1 5)              # (print 5)
# > (k2 4)              # nothing happens
# > (k1 7)              # (print 7)
#
# It's important to deactivate all continuations except for the first because
# the purpose of (amb*) is to express semantic ambivalence about the
# implementation of a given computation; therefore, we still want just one
# result despite providing two ways to calculate it.

# Compiling this representation
# The graph form is reduced to special nodes, each of which is one of the
# following:
#
# (co*     f1 f2 ... k)
# (amb*    f1 f2 ... k)
# (call*   f x1 x2 ... k)
# (nth*    i f1 f2 ... k)       # used to encode (if) and (cond)
# (fn*     n body)              # n = number of formals to bind
# (arg*    i)                   # De Bruijn index by #formals
# (global* f)                   # global function named f
#
# Here's an example function and its corresponding representation:
#
# (fn [x y]
#   (print (sqrt (+ (* x x) (* y y)))))
#
# (fn* 3                        # x y k
#   (co* (fn* 1 (call* (global* *) (arg* 1) (arg* 1) (arg* 0)))
#        (fn* 1 (call* (global* *) (arg* 2) (arg* 2) (arg* 0)))
#        (fn* 2                 # co* continuation
#          (call* (global* +) (arg* 0) (arg* 1)
#            (fn* 1
#              (call* (global* sqrt) (arg* 0)
#                (fn* 1
#                  (call* (global* print) (arg* 0) (arg* 6)))))))))
#
# In this case we can statically reclaim all memory because of the way each
# function is annotated; (*), (+), (sqrt), and (print) are each linear in their
# continuation and return values that don't alias their arguments. The ideal
# Perl compilation would look like this:
#
# sub {
#   $_[2]->(print(sqrt(($_[0]*$_[0]) + ($_[1]*$_[1]))));
# }
#
# A naive and much slower compilation would be:
#
# sub {
#   my $v1 = $_[0] * $_[0];
#   my $v2 = $_[1] * $_[1];
#   my $v3 = $v1 + $v2;
#   my $v4 = sqrt($v3);
#   my $v5 = print($v4);
#   $_[2]->($v5);
# }

{

package ni::lisp::graph;



}
