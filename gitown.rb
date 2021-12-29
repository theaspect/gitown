require 'rugged'

require 'json'
require 'date'

class StatCache
  attr_reader :commits, :blobs, :authors, :replacements

  def initialize(path, output, branch, limit, interval, replacements = {}, callback = 'callback', extensions = ['*.*'])
    @path = path
    @output = output
    @replacements = replacements
    @branch = branch
    @limit = limit
    @interval = interval
    @callback = callback
    @extensions = extensions

    @repo = Rugged::Repository.new(path)

    # Cached data
    @authors = {}
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

  def get_commit(hash)
    unless @commits.key?(hash)
      begin
        author = @repo.lookup(hash).author[:email]
      rescue StandardError => e
        puts hash
        raise e
      end
      @commits[hash] = author
      @authors[get_name(author)] = 0
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

  def annotate_file(commit, root, entry)
    if !@blobs.key?(entry[:oid]) && validate_entry(@extensions, "#{root}#{entry[:name]}")
      stats = Hash.new(0)
      command = "git --no-pager -C #{@path} blame -l -r #{commit.oid} -- '#{root}#{entry[:name]}'"
      begin
        output = `#{command}`
        output.each_line do |r|
          # looks like bug in git blame
          # command could return ^24aab5e4254889039a3aa64d810f47d487aefd9 (john 2013-04-17 21:32:40 +0400 1) some line
          author = get_commit(r[0] != '^' ? r[0, 39] : r[1, 39])
          stats[get_name(author)] += 1
        rescue StandardError => e
          puts r
          raise e
        end
      rescue StandardError => e
        puts command
        raise e
      end
      @blobs[entry[:oid]] = stats
      # noinspection RubyUnnecessaryReturnValue
      @blobs[entry[:oid]]
    else
      # puts "Skip blob"
      Hash.new(0)
    end
  end

  def get_name(name)
    if @replacements.key? name
      @replacements[name]
    else
      name
    end
  end

  def write_totals
    puts "Commits #{@commits.count}"
    puts "Blobs #{@blobs.count}"
    puts "Authors #{@authors.keys}"
  end

  def write_output(result)
    write_totals

    # Sort
    sorted_stats = result.sort_by { |k, _v| k }.to_h # {date: stats,...}
    max = 0
    sorted_stats.each do |_k, v|
      total = v.values.reduce(:+)
      max = total if max < total
    end
    # Dates
    dates = sorted_stats.keys
    # Stats per author
    stats_per_author = []
    # Iterate over author
    @authors.each_key do |author|
      author_stat = []
      dates.each do |date|
        if sorted_stats[date][author]
          author_stat.push({ date: date, value: sorted_stats[date][author] })
        else
          author_stat.push({ date: date, value: 0 })
        end
      end
      stats_per_author.push({ author: author, stats: author_stat })
    end

    begin
      File.open(@output, 'w') do |f|
        f.puts "#{@callback}("
        f.puts "[\"#{dates[0]}\",\"#{dates[-1]}\"],"
        f.puts "[0,#{max}],"
        f.puts "#{JSON.pretty_generate(@authors.keys)},"
        f.puts "#{JSON.pretty_generate(stats_per_author)});"
      end
    rescue StandardError => e
      puts "Cannot write to #{@output}"
      raise e
    end
  end

  def map_date(date, interval)
    case interval
    when 'daily'
      date.strftime('%F')
    when 'weekly'
      # First day of every week
      Date.strptime(date.strftime('%GW%V'), '%GW%V').strftime('%F')
    else
      raise "Unknown interval #{interval}"
    end
  end

  def gather_stats
    result = {}

    each_commit do |c, _time|
      # Gather stats once per day
      time = map_date(c.time, @interval)
      if result.key? time
        # puts "Skip #{time}"
        next
      end

      result[time] = inject_blobs(c) { |r, e, stats| stats.merge!(annotate_file(c, r, e)) { |_k, v1, v2| v1 + v2 } }
    end

    result
  end

  def each_commit
    commits_count = walker.count
    cc = 0
    walker.each_entry do |c|
      # Format time as "2016-12-31"
      time = c.time.strftime('%F')

      cc += 1
      print "#{cc}/#{commits_count} for #{time}\r"

      yield c, time
    end
  end

  def inject_blobs(commit, stats = Hash.new(0))
    # files_count = c.tree.count_recursive
    # puts "Files #{files_count}"
    i = 0
    commit.tree.walk_blobs(:preorder) do |r, e|
      i += 1
      blob = @repo.lookup(e[:oid])
      unless blob.binary?
        yield r, e, stats # Each blob
      end
      # puts "#{i} out of #{files_count}" if i % 100 == 0
    end
    stats
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
  config.fetch('output', 'output.json'), \
  config.fetch('branch', 'master'), \
  config.fetch('limit', 1_000_000), \
  config.fetch('interval', 'daily'), \
  config.fetch('replacements', {}), \
  config.fetch('callback', 'callback'),
  config.fetch('extensions', ['*.*'])

result = cache.gather_stats
cache.write_output result
