# Hadoop operator
The `H` operator runs a Hadoop job. For example, here's what it looks like to
use Hadoop Streaming (in this case, inside a `sequenceiq/hadoop-docker`
container):

```sh
$ docker run --detach -i -m 2G --name ni-test-hadoop \
    sequenceiq/hadoop-docker \
    /etc/bootstrap.sh -bash
```

```lazytest
if ! [[ $SKIP_DOCKER ]]; then
```

Let's start up a container and use `HS` to run a Streaming job. `H` is a
delegator, meaning that you always specify a profile (in this case `S` for
Streaming) before any command arguments.

(Note: The `until docker exec` silliness below is because we have to wait for
the hadoop container to boot up correctly. Sometimes the container gets into a
bad state and doesn't become available, in which case we nuke it and start
over. This is all just for unit testing; you won't have to worry about this
stuff if you're using ni to run hadoop jobs.)

```lazytest
start_time=0;
until docker exec -i ni-test-hadoop \
      /usr/local/hadoop/bin/hadoop fs -mkdir /test-dir; do
  if (( $(date +%s) - start_time > 60 )); then
    docker rm -f ni-test-hadoop >&2
    docker run --detach -i -m 2G --name ni-test-hadoop \
      sequenceiq/hadoop-docker \
      /etc/bootstrap.sh -bash >&2
    start_time=$(date +%s)
  fi
done
```

`S` takes three lambdas: the mapper, the combiner, and the reducer. There are
two special cases you can use instead of a normal bracketed lambda:

- `_`: skip this stage of the pipeline. If you use this for the combiner and
  reducer, then your job will be map-only.
- `:`: identity lambda. `HS:_:` is a simple way to repartition your input data,
  for example.

Hadoop input paths are specified using the input stream to a hadoop command. If
you specify something that doesn't start with `hdfs://` or `hdfst://`, the
stream will be uploaded to an HDFS tempfile and used as the job input. Notice
that we use `\<` after the hadoop command: `H` emits the output path, but not
the output data -- so if we want the data we need to read it.

```bash
$ NI_HADOOP=/usr/local/hadoop/bin/hadoop \
  ni n5 Eni-test-hadoop [HS[p'r a, a*a'] _ _ \<]
1	1
2	4
3	9
4	16
5	25
```

With a reducer:

```bash
$ NI_HADOOP=/usr/local/hadoop/bin/hadoop \
  ni n5 Eni-test-hadoop [HS[p'r a, a*a'] _ [p'r a, b+1'] \<] o
1	2
2	5
3	10
4	17
5	26
```

Now let's get a word count for `ni //license`:

```bash
$ NI_HADOOP=/usr/local/hadoop/bin/hadoop \
  ni //license Eni-test-hadoop [HS[FW pF_] _ [fAcx] \<] r10
2016	1
A	1
ACTION	1
AN	1
AND	1
ANY	2
ARISING	1
AS	1
AUTHORS	1
BE	1
```

Of course, we're also at liberty to omit the lambda brackets for brevity (I
recommend using `--explain` liberally if you plan to make a habit of this):

```bash
$ NI_HADOOP=/usr/local/hadoop/bin/hadoop \
  ni //license Eni-test-hadoop [HSFWpF_ _ fAcx \<] r10
2016	1
A	1
ACTION	1
AN	1
AND	1
ANY	2
ARISING	1
AS	1
AUTHORS	1
BE	1
```

```lazytest
docker rm -f ni-test-hadoop >&2

fi                      # $SKIP_DOCKER (lazytest condition)
```
