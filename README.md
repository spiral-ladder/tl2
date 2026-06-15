# Transaction Locking II

A toy implementation of the [Transaction Locking II] paper, based on [software transactional
memory].

Software transactional memory (STM) is an alternative to lock-based synchronization for
concurrency control. Instead of using locks to control access to shared data, we 
think of reads and writes to memory as 'transactions'. These transactions are buffered,
logged optimistically and only commited after validation.

To test:

```sh
zig build test
```

[Transaction Locking II]: https://dcl.epfl.ch/site/_media/education/4.pdf
[software transactional memory]: https://en.wikipedia.org/wiki/Software_transactional_memory
