class Tag < ApplicationRecord
  has_many :taggings, :dependent => :destroy
  has_one :classification
  virtual_has_one :category,       :class_name => "Classification"
  virtual_has_one :categorization, :class_name => "Hash"

  has_many :container_label_tag_mappings

  before_destroy :remove_from_managed_filters

  def self.list(object, options = {})
    ns = get_namespace(options)
    if ns[0..7] == "/virtual"
      ns.gsub!('/virtual/','')  # throw away /virtual
      ns, virtual_custom_attribute = MiqExpression.escape_virtual_custom_attribute(ns)
      predicate = ns.split("/")

      if virtual_custom_attribute
        predicate.map! { |x| URI::RFC2396_Parser.new.unescape(x) }
        # it is always array with one string element - name of virtual custom attribute because they are supported only
        # in direct relations
        custom_attribute = predicate.first
        object.class.add_custom_attribute(custom_attribute) if object.class < CustomAttributeMixin
      end

      begin
        predicate.inject(object) { |target, method| target.public_send(method) }
      rescue NoMethodError
        ""
      end
    else
      filter_ns(object.try(:tags) || [], ns).join(" ")
    end
  end

  def self.to_tag(name, options = {})
    File.join(Tag.get_namespace(options), name)
  end

  def self.tags(options = {})
    query = Tag.joins(:taggings)

    if options[:taggable_type].present?
      query = query.where(Tagging.arel_table[:taggable_type].eq(options[:taggable_type]))
    end

    if options[:ns].present?
      query = query.where(Tag.arel_table[:name].matches("#{options[:ns]}%"))
    end

    Tag.filter_ns(query, options[:ns])
  end

  def self.parse(list)
    if list.kind_of?(Array)
      tag_names = list.collect { |tag| tag.try(:to_s) }
      return tag_names.compact
    else
      tag_names = []

      # don't mangle the caller's copy
      list = list.dup

      # first, pull out the quoted tags
      list.gsub!(/\"(.*?)\"\s*/) { tag_names << $1; "" }

      # then, replace all commas with a space
      list.tr!(',', " ")

      # then, get whatever's left
      tag_names.concat(list.split(/\s/))

      # strip whitespace from the names
      tag_names = tag_names.map(&:strip)

      # delete any blank tag names
      tag_names = tag_names.delete_if(&:empty?)

      return tag_names.uniq
    end
  end

  # @option options :ns [String, nil]
  # @option options :cat [String, nil] optional category to add to the end (with a slash)
  # @return [String] downcases namespace or category
  def self.get_namespace(options)
    ns = options.fetch(:ns, '/user')
    ns = "" if [:none, "none", "*", nil].include?(ns)
    ns += "/" + options[:cat] if options[:cat]
    ns.include?(CustomAttributeMixin::CUSTOM_ATTRIBUTES_PREFIX) ? ns : ns.downcase
  end

  def self.filter_ns(tags, ns)
    if ns.nil?
      tags = tags.to_a    if tags.kind_of?(ActiveRecord::Relation)
      tags = tags.compact if tags.respond_to?(:compact)
      return tags
    end

    list = []
    tags.collect do |tag|
      next unless tag.name =~ %r{^#{ns}/(.*)$}i
      name = $1.include?(" ") ? "'#{$1}'" : $1
      list.push(name) unless name.blank?
    end
    list
  end

  # @param tag_names [Array<String>] list of non namespaced tags
  def self.for_names(tag_names, ns)
    fq_tag_names = tag_names.collect { |tag_name| File.join(ns, tag_name) }
    where(:name => fq_tag_names)
  end

  def self.find_by_classification_name(name, region_id = Classification.my_region_number,
                                       ns = Classification::DEFAULT_NAMESPACE, parent_id = 0)
    in_region(region_id).find_by(:name => Classification.name2tag(name, parent_id, ns))
  end

  def self.find_or_create_by_classification_name(name, region_id = Classification.my_region_number,
                                                 ns = Classification::DEFAULT_NAMESPACE, parent_id = 0)
    tag_name = Classification.name2tag(name, parent_id, ns)
    in_region(region_id).find_by(:name => tag_name) || create(:name => tag_name)
  end

  def ==(comparison_object)
    super || name.downcase == comparison_object.to_s.downcase
  end

  def category
    @category ||= Classification.find_by_name(name_path.split('/').first, nil)
  end

  def show
    category.try(:show)
  end

  def categorization
    @categorization ||=
      if !show
        {}
      else
        {
          "name"         => classification.name,
          "description"  => classification.description,
          "category"     => {"name" => category.name, "description" => category.description},
          "display_name" => "#{category.description}: #{classification.description}"
        }
      end
  end

  private

  def remove_from_managed_filters
    Entitlement.remove_tag_from_all_managed_filters(name)
  end

  def name_path
    @name_path ||= name.sub(%r{^/[^/]*/}, "")
  end
end
