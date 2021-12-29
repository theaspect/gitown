require 'rugged'

require 'json'
require 'date'

class StatCache
  attr_reader :commits, :blobs, :authors, :years, :replacements

  def initialize(path, branch, limit, interval, replacements = {}, callback = 'callback', extensions = ['*.*'])
    @path = path
    @replacements = replacements
    @branch = branch
    @limit = limit
    @interval = interval
    @callback = callback
    @extensions = extensions

    @repo = Rugged::Repository.new(@path)

    # Cached data
    @authors = {}
    @years = {}
    @commits = {}
    @blobs = {}
  end

  def walker
    Rugged::Walker.walk(
      @repo,
      show: @repo.branches[@branch].target_id,
      sort: Rugged::SORT_DATE | Rugged::SORT_TOPO | Rugged::SORT_REVERSE
    ).first(@limit)
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
      @commits[hash] = { author: author, year: year }
      @authors[get_name(author)] = 0
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

  # In case a committer has multiple emails run through replacements
  def get_name(email)
    # TODO: Could be a refactoring problem too, report to JetBrains
    @replacements.key?(email) ? @replacements[email] : email
  end

  def write_totals
    puts "Commits #{@commits.count}"
    puts "Blobs #{@blobs.count}"
    puts "Authors #{@authors.keys}"
  end

  def write_output(result, statistics, items, output, smooth)
    # Sort
    sorted_stats = result.sort_by { |k, _v| k }.to_h # {date: stats,...}
    max = 0
    sorted_stats.each do |_k, v|
      total = v[statistics].values.reduce(:+)
      max = total if max < total
    end
    # Dates
    dates = sorted_stats.keys
    # Stats per author
    stats_per_bucket = []
    # Iterate over author
    items.each_key do |stat|
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
        f.puts "#{@callback}("
        f.puts "\"#{statistics}\","
        f.puts "#{smooth},"
        f.puts "[\"#{dates[0]}\",\"#{dates[-1]}\"],"
        f.puts "[0,#{max}],"
        f.puts "#{JSON.pretty_generate(items.keys)},"
        f.puts "#{JSON.pretty_generate(stats_per_bucket)});"
      end
    rescue StandardError => e
      puts "Cannot write to #{output}"
      raise e
    end
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

  # File could be formed from several blobs so we caching each blob statistics
  def annotate_file_blob(commit, root, entry)
    return @blobs[entry[:oid]] if @blobs.key?(entry[:oid])

    author_stats = {}
    author_stats.default_proc = proc { |hash, key| hash[key] = 0 }
    year_stats = {}
    year_stats.default_proc = proc { |hash, key| hash[key] = 0 }
    command = "git --no-pager -C #{@path} blame -l -r #{commit.oid} -- '#{root}#{entry[:name]}'"
    begin
      output = `#{command}`
      output.each_line do |r|
        # looks like bug in git blame
        # command could return ^24aab5e4254889039a3aa64d810f47d487aefd9 (john 2013-04-17 21:32:40 +0400 1) some line
        author, year = get_commit_info(r[0] != '^' ? r[0, 39] : r[1, 39]).values_at(:author, :year)
        author_stats[get_name(author)] += 1
        year_stats[year] += 1
      rescue StandardError => e
        puts r
        raise e
      end
    rescue StandardError => e
      puts command
      raise e
    end
    @blobs[entry[:oid]] = { authors: author_stats, years: year_stats }
    # TODO: report intellij idea team about broken logic
    # noinspection RubyUnnecessaryReturnValue
    @blobs[entry[:oid]]
  end

  def fold_blobs(commit, stats = {})
    # files_count = c.tree.count_recursive
    # puts "Files #{files_count}"
    # i = 0
    commit.tree.walk_blobs(:preorder) do |path, entry|
      # i += 1
      blob = @repo.lookup(entry[:oid])
      if !blob.binary? && validate_entry(@extensions, "#{path}#{entry[:name]}")
        yield path, entry, stats # Each blob
      end
      # puts "#{i} out of #{files_count}" if i % 100 == 0
    end
    stats
  end

  # Iterate all commits from the first one
  def each_commit
    commits_count = walker.count
    walker.each_with_index do |commit, index|
      # Format time as "2016-12-31"
      print "#{index}/#{commits_count} for #{commit.time.strftime('%F')}\r"
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

      buckets[time] = fold_blobs(commit) do |path, entry, stats|
        stats.merge!(annotate_file_blob(commit, path, entry)) do |_k, v1, v2|
          v1.merge(v2) { |key, old, new| old + new }
        end
      end
    end

    buckets
  end
end

# {
#   "path": "/Users/name/repo", /* Required */
#   "branch": "master",
#   "limit": 1000,
#   "output": "output.json",
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

cache = StatCache.new \
  config.fetch('path'), \
  config.fetch('branch', 'master'), \
  config.fetch('limit', 1_000_000), \
  config.fetch('interval', 'daily'), \
  config.fetch('replacements', {}), \
  config.fetch('callback', 'callback'),
  config.fetch('extensions', ['*.*'])

result = cache.gather_stats
cache.write_totals
cache.write_output result, :authors, cache.authors, config.fetch('authors', 'authors.json'), config.fetch('smooth', 1)
cache.write_output result, :years, cache.years, config.fetch('years', 'years.json'), config.fetch('smooth', 1)
