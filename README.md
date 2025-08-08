# Typed ipc through sendmsg and recvmsg syscalls

This is a prototype of the following idea:

1. In unix, it is possible to transfer file descriptors through unix sockets if
   one uses sendmsg and recvmsg syscalls with "control messages".
2. In zig, it is possible to inspect types at compile time to generate code.
3. Putting both of those things together, I implement a `Channel` object which
   automatically transfers any file descriptor present as a sub(-sub)* field of
   the sent object.
4. Combined with a good greenthread system (that exploits the epoll facilities),
   we would (I haven't done that) get an inter process actor model
   implementation.
