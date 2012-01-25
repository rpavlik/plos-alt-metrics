# Copyright Martin Fenner
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require "source_helper"
require 'oauth'
require "twitter"

class Author < ActiveRecord::Base
  
  devise :rememberable, :omniauthable, :trackable
  
  has_many :positions
  has_many :authentications
  has_many :contributors, :dependent => :destroy
  has_many :works, :through => :contributors
  has_many :members
  has_many :groups, :through => :members
  has_many :friendships
  has_many :friends, :through => :friendships, :order => 'sort_name, username'
  
  # Check that no duplicate position is created
  has_many :affiliations, :through => :positions do
    def <<(*items)
      super( items - proxy_owner.affiliations )
    end
  end
  
  attr_accessible :username, :name, :mas, :mendeley, :authorclaim, :googlescholar, :twitter, :location, :description, :image, :website, :remember_me
  
  validates_numericality_of :mas, :allow_blank => true
  validates_uniqueness_of :mas, :allow_blank => true
  validates_presence_of :username
  validates_uniqueness_of :username
  
  default_scope :order => 'authors.sort_name'
  
  scope :limit, lambda { |limit| (limit && limit > 0) ? {:limit => limit} : {} }
  
  def self.find_for_twitter_oauth(omniauth)
     authentication = Authentication.find_by_provider_and_uid(omniauth['provider'], omniauth['uid'])
     if authentication && authentication.author
       authentication.author
     else
       author = Author.find_or_create_by_username(:username => omniauth['user_info']['nickname'], 
                               :twitter => omniauth['uid'],
                               :name => omniauth['user_info']['name'])
       authentication = Authentication.create!(:provider => omniauth['provider'], 
                                      :uid => omniauth['uid'],
                                      :token => omniauth['credentials']['token'],
                                      :secret => omniauth['credentials']['secret'])                            
       author.authentications << authentication
       author.save

       # Fetch additional properties from Twitter
       self.update_via_twitter(author)
       author
     end
   end
  
  def stale?
    new_record? or author.works.empty?
  end

  def refreshed!
    self.updated_at = Time.now
    self
  end
  
  def to_json(options={})
    result = { 
      :author => { 
        :name => name,
        :mas => mas, 
        :mendeley => mendeley, 
        :authorclaim => authorclaim,
        :location => location,
        :description => description,
        :website => website,
        :works_count => works_count,
        :updated_at => updated_at
      }
    }
    
    @categories = Category.find :all, :conditions => ["sources.active=1"], :include => :sources, :order => :category_id
    result[:author][:citations] = []
    @categories.each do |category|
		  category.sources.reusable.each do |source|
	      result[:author][:citations] << {:source_id => source.id, :source_name => source.name, :count => self.citations_count(source)}
	    end
    end
    
    result[:author][:works] = []
    self.works.each do |work|
      result[:author][:works] << {:doi => work.doi, 
        :shortdoi => work.short_doi,
        :title => work.title, 
        :year => work.year,
        :pub_med => work.pub_med,
        :pub_med_central => work.pub_med_central,
        :mas => work.mas,
        :mendeley => work.mendeley,
        :citations_count => work.citations_count,
        :published => (work.published_on.blank? ? nil : work.published_on.to_time),
        :updated_at => work.retrieved_at}
    end
    
    result.to_json(options)
  end
  
  def to_bib
    bibliography = BibTeX::Bibliography.new
    self.works.each do |work|
      bibliography << work.bib_entry
    end
    bibliography
  end
  
  def works_count
    self.works.count
  end
  
  def display_name
  	(self.native_name.blank? ? "" : self.native_name + " (") + (self.name.blank? ? self.mas : self.name) +  (self.native_name.blank? ? "" : ")")
	end
	
	def has_profile
	  !mas.blank? or !authorclaim.blank? or !mendeley.blank? or !googlescholar.blank?
	end
  
  def self.fetch_properties(author, options={})
    # Fetch author information, return nil if no response 
    return nil if author.mas.blank?
    
    url = "http://academic.research.microsoft.com/json.svc/search?AppId=#{APP_CONFIG['mas_app_id']}&ResultObjects=Author&AuthorID=#{author.mas}&StartIdx=1&EndIdx=1"
    Rails.logger.info "Microsoft Academic Search query: #{url}"
    
    result = SourceHelper.get_json(url, options)["d"]["Author"]
    return nil if result.nil?
    
    properties = result["Result"][0]
  end
  
  def self.update_properties(author, properties, options={})
    # Update author information
    author.update_attributes(:sort_name => properties["LastName"].to_s.capitalize, :native_name => properties["NativeName"])
    
    # Update affiliation information
    af_properties = properties["Affiliation"]
    unless af_properties.nil?
      affiliation = Affiliation.find_or_create_by_mas(:mas  => af_properties["ID"], :name => af_properties["Name"], :homepageURL => af_properties["HomepageURL"])
      author.affiliations << affiliation
    end
    author
  end
  
  def self.search_for_mas_authors(author, options={})
    # Fetch author information, return nil if no response 
    return nil if author.name.blank?
    url = "http://academic.research.microsoft.com/json.svc/search?AppId=#{APP_CONFIG['mas_app_id']}&AuthorQuery=#{CGI.escape(author.name)}&ResultObjects=Author&StartIdx=1&EndIdx=10"
    Rails.logger.info "Microsoft Academic Search query: #{url}"
    
    result = SourceHelper.get_json(url, options)["d"]["Author"]
    return nil if result.nil?
    
    properties = result["Result"]
    choices = []
    properties.each do |property|
      affiliation = property["Affiliation"].nil? ? "" : " (" + property["Affiliation"]["Name"] + ")"
      name_and_affiliation = (property["FirstName"].to_s.blank? ? "" : property["FirstName"].to_s.capitalize + " ") + (property["MiddleName"].to_s.blank? ? "" : property["MiddleName"].to_s.capitalize + " ") + (property["LastName"].to_s.blank? ? "" : property["LastName"].to_s.capitalize + affiliation + " - " + property["ID"].to_s)
      choices << [name_and_affiliation, property["ID"]]
    end
    choices
  end
  
  def self.search_for_scopus_authors(author, options={})
    # Fetch author information, return nil if no response 
    return nil if author.name.blank?
    url = "http://academic.research.microsoft.com/json.svc/search?AppId=#{APP_CONFIG['mas_app_id']}&AuthorQuery=#{CGI.escape(author.name)}&ResultObjects=Author&StartIdx=1&EndIdx=10"
    Rails.logger.info "Microsoft Academic Search query: #{url}"
    
    result = SourceHelper.get_json(url, options)
    return nil if result.nil?
    
    properties = result["Result"]
    choices = []
    properties.each do |property|
      affiliation = property["Affiliation"].nil? ? "" : " (" + property["Affiliation"]["Name"] + ")"
      name_and_affiliation = (property["FirstName"].to_s.blank? ? "" : property["FirstName"].to_s.capitalize + " ") + (property["MiddleName"].to_s.blank? ? "" : property["MiddleName"].to_s.capitalize + " ") + (property["LastName"].to_s.blank? ? "" : property["LastName"].to_s.capitalize + affiliation + " - " + property["ID"].to_s)
      choices << [name_and_affiliation, property["ID"]]
    end
    choices
  end
  
  def self.update_via_twitter(author, options={})
    begin
      # Update author info. Leave image empty if Twitter provides only default profile image
      user = Twitter.user(author.username)
      image = Twitter.profile_image(author.username, :size => 'original')
      image = nil if image.match(/default_profile_images/)
      author.update_attributes(:twitter => user.id, :location => user.location, :description => user.description, :website => user.url, :image => image)

      # Find Twitter friends
      friends_ids = Twitter.friend_ids(author.username).ids
      unless friends_ids.blank?
        author.friendships.clear
        friends_ids.each do |friend_id|
          friend = Author.find_by_twitter(friend_id)
          if friend and !author.friends.include?(friend)
            author.friends << friend 
          end
        end
      end
    rescue Twitter::Unauthorized
      Rails.logger.debug "Twitter query error: not authorized to get friends from #{author.username}"
    rescue Twitter::BadRequest
      Rails.logger.debug "Twitter rate limit exceeded"
    end
    
    author
  end
  
  def self.fetch_works_from_mas(author, options={})
    # Fetch works, return empty array if no mas identifier, no response, or no works found
    return [] if author.mas.blank?
    
    url = "http://academic.research.microsoft.com/json.svc/search?AppId=#{APP_CONFIG['mas_app_id']}&ResultObjects=Publication&PublicationContent=AllInfo&AuthorID=#{author.mas}&StartIdx=1&EndIdx=50"
    Rails.logger.info "Microsoft Academic Search query: #{url}"
    
    result = SourceHelper.get_json(url, options)["d"]["Publication"]
    return [] if result.nil?
    
    works = result["Result"]
  end
  
  def self.fetch_works_from_authorclaim(author, options={})
    # Fetch works, return empty array if no authorclaim identifier, no response, or no works found
    return [] if author.authorclaim.blank?
    
    url = "ftp://ftp.authorclaim.org/#{author.authorclaim[1,1].to_s}/#{author.authorclaim[2,1].to_s}/#{author.authorclaim}.amf.xml"
    Rails.logger.info "AuthorClaim query: #{url}"
    
    SourceHelper.get_xml(url, options) do |document|
      results = []
      document.root.namespaces.default_prefix = 'amf'
      person = document.find_first("//amf:person")
      contributor = {}
      contributor["given_name"] = ""
      contributor["given_name"] << person.find_first("amf:givenname").content if person.find_first("amf:givenname")
      contributor["given_name"] << (contributor["given_name"].blank? ? "" : " ") + person.find_first("amf:additionalname").content if person.find_first("amf:additionalname")
      contributor["surname"] = person.find_first("amf:familyname").content if person.find_first("amf:familyname")
      document.find("//amf:isauthorof/amf:text").each do |work|
        ref = work.attributes.get_attribute("ref").value
        # Only use work if reference has DOI
        next unless ref.match(/^info:lib\/crossref:/)
        result = {}
        result["DOI"] = CGI::unescape(ref[18..-1])
        result["Title"] = work.find_first("amf:title").content
        results << result
      end
      { :contributor => contributor, :works => results }
    end
  end
  
  def self.fetch_works_from_scopus(author, options={})
    # Fetch works, return empty array if no mas identifier, no response, or no works found
    return [] if author.scopus.blank?
    
    url = "http://api.elsevier.com/content/author/AUTHOR_ID:#{author.scopus}"
    options[:extraheaders] = { "Accept"  => "application/json", "X-ELS-APIKey" => APP_CONFIG['scopus_key'], "X-ELS-ResourceVersion" => "XOCS" }
    
    Rails.logger.info "Scopus query: #{url}"
    
    result = SourceHelper.get_json(url, options)
    return [] if result.nil?
    
    works = result["Result"]
  end
  
  def citations_count(source=nil, options={})
    citations = []
    works.each do |work|
      unless source.nil?
        citations << work.retrievals.sum(:citations_count, :conditions => ["retrievals.source_id = ?", source])
        citations << work.retrievals.sum(:other_citations_count, :conditions => ["retrievals.source_id = ?", source])
      else
        citations << work.retrievals.sum(:citations_count)
        citations << work.retrievals.sum(:other_citations_count)
      end
    end
    citations = citations.sum
  end
  
  def get_cites_by_category(categoryname)
    citations = []
    categoryname = categoryname.downcase
    works.each do |work|
      citations << work.retrievals.map do |ret|
        if ret.source.category.name.downcase == categoryname && (ret.citations_count + ret.other_citations_count) > 0
          #Cast this to an array to get around a ruby 'singularize' bug
          { :name => ret.source.name.downcase, :citations => ret.citations.to_a }
        end
      end.compact
    end
    citations = citations.sum
  end
  
end