require "sinatra"
require 'yaml'
require 'mimemagic'
require 'nokogiri'
require 'mp3info'
require 'mp4info'

class AudiobookApplication < Sinatra::Base

  ROOT_DIR = File.dirname(__FILE__)
  CONFIG_FILE = File.join(ROOT_DIR, 'config.yml')
  CONFIG = OpenStruct.new(YAML::load(File.open(CONFIG_FILE)))

  DATE_START = Time.new('2000-01-01')

  before do
    if request.path.match(/\/$/)
      redirect remove_slash request
    end
  end

  get '/favicon.ico' do
  end

  get '/' do
    @authors = Dir.entries(CONFIG.root).sort.select do |filename|
      path = File.join(CONFIG.root, filename)
      !filename.match(/^\./) && File.directory?(path)
    end
    slim :root
  end
  
  get '/:author' do
    @author = delinkify params[:author]
    path = File.join(CONFIG.root, @author)
    @books = Dir.entries(path).sort.select do |filename|
      book_path = File.join(path, filename)
      !filename.match(/^\./) && File.directory?(book_path)
    end
    slim :author
  end

  get '/:author/:book' do
    @author = delinkify params[:author]
    @book = delinkify params[:book]
    path = File.join(CONFIG.root, @author, @book)
    @files = audio_files path
    slim :book
  end

  get '/:author/:book/feed.?:format?' do
    author = delinkify params[:author]
    book = delinkify params[:book]
    path = File.join(CONFIG.root, author, book)
    files = audio_files path
    files.reverse! if params[:reverse]
    pubDate = DATE_START
    builder = Nokogiri::XML::Builder.new do |xml|
      xml.rss :'xmlns:itunes' => "http://www.itunes.com/dtds/podcast-1.0.dtd", version:"2.0" do
        xml.channel do
          xml.title "#{author} - #{book}"
          xml.author author
          xml.send(:'itunes:author', author)
          xml.subtitle book
          xml.description "#{book} by #{author}"
          xml.send(:'itunes:summary', "#{book} by #{author}")
          xml.link xml_channel_link(request, author, book)
          files.each do |file|
            xml.item do
              duration = file_duration(file[:full_path])
              xml.title file[:path]
              xml.send(:'itunes:author', author)
              xml.enclosure url: xml_file_link(request, author, book, file[:path]), length: file[:size]
              xml.link xml_file_link(request, author, book, file[:path])
              xml.guid xml_file_link(request, author, book, file[:path])
              xml.duration duration if duration
              xml.pubDate pubDate.rfc2822
            end
            pubDate += (60*60*24)
          end
        end
      end
    end
    content_type :xml
    builder.to_xml
  end

  get '/:author/:book/file/*' do 
    author = delinkify params[:author]
    book = delinkify params[:book]
    file = delinkify params[:splat].first
    path = File.join(CONFIG.root, author, book, file)
    send_file path
  end

  get '/:author/:book/cover' do 
    author = delinkify params[:author]
    book = delinkify params[:book]
    path = File.join(CONFIG.root, author, book)
    cover = directory_cover path
    return send_file cover if cover
  end

  get '/:author/:book/cover/*' do 
    author = delinkify params[:author]
    book = delinkify params[:book]
    file = delinkify params[:splat].first
    path = File.join(CONFIG.root, author, book, file)
    mime = MimeMagic::by_path(path)
    if mime.to_s == 'audio/mp4' || mime.child_of?('audio/mp4')
      Mp4Info.open(path).tag.COVR
    elsif mime.to_s == 'audio/mpeg'
      Mp3Info.open(path).tag.pictures
    else
      "Unkown filetype `#{mime.to_s}`"
    end
  end

  helpers do
    def linkify str
      str.gsub(' ', '+')
    end

    def delinkify str
      str.gsub('+', ' ')
    end

    def xml_channel_link request, author, book
      "#{request.scheme}://#{request.host}/#{linkify(author)}/#{linkify(book)}"
    end

    def xml_file_link request, author, book, file
      "#{request.scheme}://#{request.host}/#{linkify(author)}/#{linkify(book)}/file/#{linkify(file)}"
    end

    def audio_files path
      Dir.glob(File.join(path, '**/*')).sort.map do |full_path|
        {
          full_path: full_path,
          path: full_path.gsub(path, '').gsub(/^\/+/, ''),
          mime: MimeMagic::by_path(full_path).to_s,
          size: File.size(full_path),
          duration: file_duration(full_path)
        }
      end.select do |file|
        file[:mime].match(/^audio/)
      end
    end

    def file_duration path
      mime = MimeMagic::by_path(path)
      return unless mime
      if mime.to_s == 'audio/mp4' || mime.child_of?('audio/mp4')
        Mp4Info.open(path).SECS
      elsif mime.to_s == 'audio/mpeg'
        length = Mp3Info.open(path).length

        "%02d:%02d" % [length / 60, length % 60] 
      end
    end
    
    def remove_slash request
      request.path.gsub(/\/+$/,'') + (request.query_string.size > 0 ? ('?' + request.query_string) : '')
    end

    def human_size bytes
      return "%dB" % [bytes] if bytes < 1024
      return "%.2fKB" % [bytes / 1024] if bytes < 1024 * 1024
      return "%.2fMB" % [bytes / (1024 * 1024)] if bytes < 1024 * 1024 * 1024
      return "%.2fMB" % [bytes / (1024 * 1024 * 1024)] if bytes < 1024 * 1024 * 1024 * 1024
      return "%.2fGB" % [bytes / (1024 * 1024 * 1024 * 1024)] if bytes < 1024 * 1024 * 1024 * 1024 * 1024
    end

    def directory_cover path
      Dir.glob(File.join(path, '**/cover.*')).find do |full_path|
        MimeMagic::by_path(full_path).to_s.match(/^image/)
      end
    end
  end
end
