require 'google/api_client'
require 'google/api_client/client_secrets'
require 'google/api_client/auth/installed_app'
require 'google/api_client/auth/storage'
require 'google/api_client/auth/storages/file_store'
require 'fileutils'
require 'json'
require 'base64'
require 'nokogiri'

APPLICATION_NAME = 'Canned Response Creator'
CLIENT_SECRETS_PATH = 'client_secret.json'
CREDENTIALS_PATH = File.join(Dir.home, '.credentials', "gmail-quickstart.json")
SCOPE = 'https://www.googleapis.com/auth/gmail.readonly'

@mimetypes = {}
@encodings = {}

def authorize
  FileUtils.mkdir_p(File.dirname(CREDENTIALS_PATH))

  file_store = Google::APIClient::FileStore.new(CREDENTIALS_PATH)
  storage = Google::APIClient::Storage.new(file_store)
  auth = storage.authorize

  if auth.nil? || (auth.expired? && auth.refresh_token.nil?)
    app_info = Google::APIClient::ClientSecrets.load(CLIENT_SECRETS_PATH)
    flow = Google::APIClient::InstalledAppFlow.new({
      :client_id => app_info.client_id,
      :client_secret => app_info.client_secret,
      :scope => SCOPE})
    auth = flow.authorize(storage)
    puts "Credentials saved to #{CREDENTIALS_PATH}" unless auth.nil?
  end
  auth
end

def strip_html(str)
  document = Nokogiri::HTML.parse(str)
  document.css("br").each { |node| node.replace("\n") }
  document.inner_text
end


def track_mimetypes(mt)
  if @mimetypes[mt].nil?
    @mimetypes[mt] = 1
  else
    @mimetypes[mt] += 1
  end
end

def track_encodings(encoding)
  if @encodings[encoding].nil?
    @encodings[encoding] = 1
  else
    @encodings[encoding] += 1
  end
end

def get_message_json(id)
  msg = @client.execute!(
    :api_method => @gmail_api.users.messages.get,
    :parameters => { 
      :id => id,
      :userId => 'me',
      :format => 'full'
     }
    )

  msg.data.to_json
end


def get_string_from_message_part(part,html=false)
  msg_string = ""

  #record mimeTypes
  track_mimetypes(part['mimeType'])

  #extract en decode string
  encoded_string = part['body']['data']
  if !encoded_string.nil?
    msg_string << Base64.urlsafe_decode64(encoded_string)
    msg_string << "\n\n"
  end

  if html
    strip_html(msg_string)
  end

  track_encodings(msg_string.encoding)
  msg_string
end


def get_string_from_payload(payload)
  string = ""
  mimetype =  payload['mimeType']
  mimetype_cat = mimetype.split("/")[0]

  if mimetype_cat == "multipart"
    track_mimetypes("unbundled:"+payload['mimeType'])
    payload['parts'].each do |part|
      string << get_string_from_payload(part)
    end
  elsif mimetype == "text/plain"
    string << get_string_from_message_part(payload)
  elsif mimetype == "text/html"
    string << get_string_from_message_part(payload,true)
  else
    track_mimetypes("unprocessed:"+payload['mimeType'])
  end

  string
end


def get_message_string_from_id(id)
  msg_json = JSON.parse(get_message_json(id))
  msg_payload = msg_json['payload']

  msg_string = ""
  msg_string = get_string_from_payload(msg_payload)
  msg_string
end



#Initialize the API
@client = Google::APIClient.new(:application_name => APPLICATION_NAME)
@client.authorization = authorize
@gmail_api = @client.discovered_api('gmail','v1')

#Extract all the text in messages
results = @client.execute!(
  :api_method => @gmail_api.users.messages.list,
  :parameters => { 
    :userId => 'me',
    :includeSpamTrash => false,
    :q => "from:me",
    :fields => "messages(id,labelIds,payload,snippet),nextPageToken,resultSizeEstimate"
   }
  )

puts "Messages:"
puts "No messages found" if results.data.messages.empty?

results.data.messages.each do |message|
  puts "- #{message.id}"
  msg_string = get_message_string_from_id(message.id)
  puts "-- #{msg_string}"
  puts @mimetypes
  puts @encodings
end


