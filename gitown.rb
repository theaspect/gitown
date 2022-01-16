require 'rugged'

require 'json'
require 'date'

# TODO: no file close
# TODO: cache whole days stats
class StatCache
  attr_reader :commits, :authors, :merged_authors, :limited_authors, :years, :replacements, :cache, :cache_file

  # TODO: decompose into cache, writer, walker
  def initialize(path, branch, limit, start, interval, replacements = {}, callback = 'callback', extensions = ['*.*'], cache_path)
    @path = path
    @replacements = replacements
    @branch = branch
    @limit = limit
    @start = Date.parse(start).to_time
    @interval = interval
    @callback = callback
    @extensions = extensions

    @repo = Rugged::Repository.new(@path)

    # Cached data
    @authors = {}
    @merged_authors = {}
    @limited_authors = {}
    @years = {}
    @commits = {}
    @cache = read_cache_if_exists(cache_path)
    @cache_file = File.open(cache_path, 'a')
  end

  def walker
    Rugged::Walker.walk(
      @repo,
      show: @repo.branches[@branch].target_id,
      sort: Rugged::SORT_DATE | Rugged::SORT_TOPO | Rugged::SORT_REVERSE
    ).drop_while do |commit|
      commit.time < @start
    end.first(@limit)
  end

  # Return author: and year:
  def get_commit_info(hash)
    unless @commits.key?(hash)
      begin
        object = @repo.lookup(hash)
        author = object.author[:email]
        year = Time.at(object.epoch_time).year
      rescue StandardError => e
        puts hash
        raise e
      end
      # TODO: Here comes side effects
      @commits[hash] = { author: author, year: year }
      @authors[author] = 0
      @years[year] = 0
      # else
      # puts "Skip author"
    end
    @commits[hash]
  end

  # Could be used to quickly fild all extensions
  # find ../risk | rev | cut -d'.' -f1 | rev | sort -u
  def validate_entry(rules, name)
    rules.any? { |ext| File.fnmatch(ext, name) }
  end

  def write_totals
    puts "Authors #{@authors.keys}"
    puts "Commits #{@commits.count}"
    puts "Blobs #{cache.count}"
  end

  def merge_names(result)
    merged = {}
    result.each do |year, stats|
      merged[year] = { 'years' => stats['years'], 'authors' => {} }
      stats['authors'].each do |email, count|
        name = get_name(email)
        @merged_authors[name] = 0
        merged[year]['authors'][name] = 0 unless merged[year]['authors'].key?(name)
        merged[year]['authors'][name] += count
      end
    end
    merged
  end

  # In case a committer has multiple emails run through replacements
  def get_name(email)
    # TODO: Could be a refactoring problem too, report to JetBrains
    @replacements.key?(email) ? @replacements[email] : email
  end

  def limit_authors(result, limit)
    max_counts = {}
    result.each do |_, stats|
      stats['authors'].each do |email, count|
        max_counts[email] = 0 unless max_counts.key?(email)
        max_counts[email] = count if max_counts[email] < count
      end
    end

    # Kee only top commiters
    max_counts = max_counts
                 .sort_by { |_, v| -v }
                 .take(limit)
                 .each_with_object({}) do |(k, v), acc|
                   acc[k] = v
                 end

    limited = {}
    result.each do |year, stats|
      limited[year] = { 'years' => stats['years'], 'authors' => {} }
      stats['authors'].each do |email, count|
        name = max_counts.key?(email) ? email : 'Others'
        @limited_authors[name] = 0
        limited[year]['authors'][name] = 0 unless limited[year]['authors'].key?(name)
        limited[year]['authors'][name] += count
      end
    end

    limited
  end

  def truncate_date(date, interval)
    case interval
    when 'daily'
      date.strftime('%F')
    when 'weekly'
      # First day of every week
      # %G - The week-based year
      # %V - Week number of the week-based year (01..53)
      # %GW%V formatted as 2021W53 then parsed back to dat effectively trim to first day of week
      # Then format as iso date
      # %F - The ISO 8601 date format (%Y-%m-%d)
      Date.strptime(date.strftime('%GW%V'), '%GW%V').strftime('%F')
    when 'monthly'
      # Same as above
      # %m - Month of the year, zero-padded (01..12)
      Date.strptime(date.strftime('%Y%m'), '%Y%m').strftime('%F')
    else
      raise "Unknown interval #{interval}"
    end
  end

  # TODO: good section to move into cache class, which will manage file on it's own
  def read_cache_if_exists(path)
    buckets = {}
    # Read cache
    if File.exist?(path)
      begin
        File.readlines(path).each do |line|
          buckets[line[0..39]] = JSON.parse(line[41..-1])
        end
      rescue StandardError => e
        puts("Error during cache load #{e}")
      end
    else
      puts "File #{path} not found"
    end
    buckets
  end

  def get_blob(oid)
    @cache[oid]
  end

  def put_blob(oid, counts)
    @cache[oid] = counts
    # This is not pure JSON because I want to have a appendable cache
    @cache_file.write "#{oid}\t#{JSON.generate(counts)}\n"
    @cache_file.flush
  end

  # File could be formed from several blobs so we caching each blob statistics
  def annotate_file_blob(commit, root, entry)
    blob = get_blob(entry[:oid])
    if blob
      blob['authors'].keys.each { |k| @authors[k] = 0 }
      blob['years'].keys.each { |k| @years[k] = 0 }
      return blob
    end

    author_stats = {}
    year_stats = {}
    command = "git --no-pager -C #{@path} blame -l -r #{commit.oid} -- '#{root}#{entry[:name]}'"
    begin
      output = `#{command}`
      output.each_line do |r|
        # looks like bug in git blame
        # command could return ^24aab5e4254889039a3aa64d810f47d487aefd9 (john 2013-04-17 21:32:40 +0400 1) some line
        author, year = get_commit_info(r[0] != '^' ? r[0, 39] : r[1, 39]).values_at(:author, :year)
        author_stats[author] = 0 unless author_stats.key?(author)
        author_stats[author] += 1
        year_stats[year] = 0 unless year_stats.key?(year)
        year_stats[year] += 1
      rescue StandardError => e
        puts r
        raise e
      end
    rescue StandardError => e
      puts command
      raise e
    end

    results = { authors: author_stats, years: year_stats }
    put_blob(entry[:oid], results)
    results
  end

  def fold_blobs(commit, stats = {})
    files_count = commit.tree.count_recursive
    puts "Files #{files_count}"
    i = 0
    commit.tree.walk_blobs(:preorder) do |path, entry|
      i += 1
      blob = @repo.lookup(entry[:oid])
      if !blob.binary? && validate_entry(@extensions, "#{path}#{entry[:name]}")
        yield path, entry, stats # Each blob
      end
      puts "#{i} out of #{files_count}" if (i % 1000).zero?
    end
    stats
  end

  # Iterate all commits from the first one
  def each_commit
    #commits_count = walker.count
    walker.each_with_index do |commit, index|
      # Format time as "2016-12-31"
      # puts "#{index}/#{commits_count} for #{commit.time.strftime('%F')}"
      yield commit
    end
  end

  def gather_stats
    buckets = {}

    each_commit do |commit|
      # Gather stats once per day
      time = truncate_date(commit.time, @interval)
      # If this bucket already exists then skip it
      if buckets.key? time
        # puts "Skip #{time}"
        next
      end

      puts "Matched #{time}"
      buckets[time] = fold_blobs(commit) do |path, entry, stats|
        stats.merge!(annotate_file_blob(commit, path, entry)) do |_k, v1, v2|
          v1.merge(v2) { |key, old, new| old + new }
        end
      end
    end

    buckets
  end
end

# TODO: calculate items on the way
def write_output(result, statistics, items, callback, output, smooth)
  # Sort
  sorted_stats = result.sort_by { |k, _v| k }.to_h # {date: stats,...}
  # Find maximum range across all days to have a chart range
  max = 0
  sorted_stats.each do |_k, v|
    total = v[statistics].values.reduce(:+)
    max = total if max < total
  end
  # Dates
  dates = sorted_stats.keys
  # Stats per author
  stats_per_bucket = []
  # Iterate over author or year
  items.keys.sort.each do |stat|
    author_stat = []
    dates.each do |date|
      if sorted_stats[date][statistics][stat]
        author_stat.push({ date: date, value: sorted_stats[date][statistics][stat] })
      else
        author_stat.push({ date: date, value: 0 })
      end
    end
    stats_per_bucket.push({ author: stat, stats: author_stat })
  end

  begin
    File.open(output, 'w') do |f|
      f.puts "#{callback}("
      f.puts "\"#{statistics}\","
      f.puts "#{smooth},"
      f.puts "[\"#{dates[0]}\",\"#{dates[-1]}\"],"
      f.puts "[0,#{max}],"
      f.puts "#{JSON.pretty_generate(items.keys.sort)},"
      f.puts "#{JSON.pretty_generate(stats_per_bucket)});"
    end
  rescue StandardError => e
    puts "Cannot write to #{output}"
    raise e
  end
end

# {
#   "path": "/Users/name/repo", /* Required */
#   "branch": "master",
#   "limit": 1000,
#   "replacements": {
#     "john.doe@example.com": "J.Doe"
#   }
# }

# Parse config
config_file = ARGV[0] || 'config.json'
begin
  config = JSON.parse(File.read(config_file))
  puts config
rescue StandardError => e
  puts "Cannot parse #{config_file}"
  puts 'Run ruby gitown.rb config.json'
  raise e
end

# TODO: probably makes sense to store only repo name and save files as suffixes
#  defaults to repo name
cache = StatCache.new \
  config.fetch('path'), \
  config.fetch('branch', 'master'), \
  config.fetch('limit', 1_000_000), \
  config.fetch('start', '1990-01-01'), \
  config.fetch('interval', 'daily'), \
  config.fetch('replacements', {}), \
  config.fetch('callback', 'callback'),
  config.fetch('extensions', ['*.*']),
  config.fetch('cache', 'blobs.cache')

result = cache.gather_stats
result = cache.merge_names(result)
result = cache.limit_authors(result, config.fetch('collapse', 25))
cache.write_totals

write_output result, 'authors', \
             cache.limited_authors, \
             config.fetch('callback', 'callback'), \
             config.fetch('authors', 'authors.json'), \
             config.fetch('smooth', 1)

write_output result, 'years', \
             cache.years, \
             config.fetch('callback', 'callback'), \
             config.fetch('years', 'years.json'), \
             config.fetch('smooth', 1)
