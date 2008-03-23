require "set"

##
# This module provides a number of +Classifier+ classes that are instantiated,
# trained with sample text, and used to classify new bits of text. The base
# class, +Classifier+, provides the basic capabilities. Two sub-classes,
# +NaiveBayes+ and +Fisher+ provide more specific classification abilities.
#
# All of these classes require the same basic steps to be useful:
# * Create a new instance, passing a block to extract features from the text
# * Train the classifier by invoking the +train+ method as needed
# * Have the classifier classify new, unseen text (varies by sub-class)
module Filtering
  
  ##
  # Pull all of the words out of a given doc +String+ and normalize them.
  # This is the default feature-extraction function used by all +Classifiers+.
  def self.get_words(doc)
    words = Set.new
    doc.split(/\s+/).each do |word|       
      words << word.downcase if word.size > 2 && word.size < 20
    end
    words
  end

  ##
  # A +Classifier+ is an object that is trained with blocks of text and
  # expected categories. After training, the +Classifier+ can classify
  # new blocks of text based on its training.
  class Classifier
    
    ##
    # A +Hash+ where thresholds can be set for a particular category.
    # These values are used by the +classify+ method.
    attr_reader :thresholds

    ##
    # Construct a new instance.
    # This requires a block that will accept a single item
    # and returns its features
    # == Parameters
    # * <tt>filename</tt>
    # * <tt>block</tt> - A block that extracts features from a given block of text. If one isn't specified, the +get_words+ function is used.
    def initialize(filename=nil, &block)
      if block_given?
        @get_features_func = block
      else
        @get_features_func = lambda { |item| Filtering.get_words(item) }
      end
      @feature_count = Hash.new do |h,k|
        h[k] = Hash.new { |h2,k2| h2[k2] = 0 }
      end
      @category_count = Hash.new { |h,k| h[k] = 0 }
      @thresholds = {}
      @thresholds.default = 0
    end

    ##
    # Returns the number of occurrences of a given +feature+ for
    # a given +category+.
    # == Example
    #   classifier = Filtering::Classifier.new
    #
    #   classifier.train("the quick brown fox jumps over the lazy dog", :good)
    #   classifier.train("make quick money in the online casino", :bad)
    #
    #   classifier.feature_count("quick", :good) #=> 1.0
    #   classifier.feature_count("quick", :bad)  #=> 1.0
    #   classifier.feature_count("dog", :good)   #=> 1.0
    #   classifier.feature_count("dog", :bad)    #=> 0.0
    def feature_count(feature, category)
      if @feature_count.has_key?(feature) && @category_count.has_key?(category)
        @feature_count[feature][category].to_f
      else
        0.0
      end
    end
    
    ##
    # Train the classifier by passing an +item+ and the expected +category+.
    # Features will be extracted from the +item+ using the block provided
    # in the constructor
    # == Parameters
    # * <tt>item</tt> - The block of text to train with
    # * <tt>category</tt> - The category to associate with this text (best done with a symbol)
    # == Example
    #   classifier = Filtering::Classifier.new do |item|
    #     Filtering.get_words(item)
    #   end
    #   classifier.train("the quick brown fox jumps over the lazy dog", :good)
    #   classifier.train("make quick money in the online casino", :bad)
    def train(item, category)
      features = get_features(item)
      # increment the feature count
      features.each do |feature|
        increment_feature(feature, category)
      end
      # increment he category count
      increment_category(category)
    end
   
    ##
    # Returns the probably (between 0.0 and 1.0) of a feature
    # for a given category. Pr(feature | category)
    def feature_probability(feature, category)
      return 0 if category_count(category) == 0
      feature_count(feature, category) / category_count(category)
    end
    
    ##
    # Returns the weighted probability of a feature for a given category
    # using the +prf+ function to calculate with the given
    # +weight+ and +assumed_prob+ variables (both of which have defaults)
    # == Parameters
    # * <tt>feature</tt> - The feature to calculate probability for
    # * <tt>category</tt> - The category to calculate probability
    # * <tt>prf</tt> - a probability function
    # * <tt>weight</tt> - defaults to 1.0
    # * <tt>assumed_prob</tt> - defaults to 0.5
    # * <tt>block</tt> - A block to calculate probability of a feature for a category
    # == Example
    #  classifier = Filtering::Classifier.new
    #  
    #  fprob = lambda { |f,c| classifier.feature_probability(f, c) }
    #  
    #  classifier.train("the quick brown fox jumps over the lazy dog", :good)
    #  classifier.train("make quick money in the online casino", :bad)
    #
    #  prob = classifier.weighted_probability("money", :good) do |f, c|
    #    classifier.feature_probability(f, c)
    #  end.should
    #
    #   #=> prob = 0.25
    def weighted_probability(feature, category, weight=1.0, assumed_prob=0.5, &block)
      raise "You must provide a block" unless block_given?
      basic_probabilty = block.call(feature, category)
      
      totals = 0
      categories.each do |category|
        totals += feature_count(feature, category)
      end
      
      ((weight * assumed_prob) + (totals * basic_probabilty)) / (weight + totals)
    end
    
    ##
    # Classify a given +item+ based on training done by calls to the +train+
    # method.
    # == Parameters
    # * <tt>item</tt> - A block of text to classify
    # * <tt>default</tt> - A default category if one cannot be determined
    # == Example
    #   classifier = Filtering::Classifier.new
    #
    #   classifier.train("Nobody owns the water", :good)
    #   classifier.train("the quick rabbit jumps fences", :good)
    #   classifier.train("buy pharmaceuticals now", :bad)
    #   classifier.train("make quick money at the online casino", :bad)
    #   classifier.train("the quick brown fox jumps", :good)
    #
    #   classifier.classify("quick rabbit", :unknown)   #=> :good
    #   classifier.classify("quick money", :unknown)    #=> :bad
    #   classifier.classify("chocolate milk", :unknown) #=> :unknown
    def classify(item, default=nil)
      probs = {}
      probs.default = 0.0
      max = 0.0
      best = nil
      categories.each do |cat|
        probs[cat] = prob(item, cat)
        if probs[cat] > max
          max = probs[cat]
          best = cat
        end
      end
      
      probs.each do |cat, prob|
        next if cat == best
        if probs[cat] * thresholds[best] > probs[best]
          return default
        end
      end
      best
    end

    private
    ##
    # Invokes the block given in the +initialize+ method to
    # extract features for the given +item+
    def get_features(item)
      @get_features_func.call(item)
    end

    def increment_feature(feature, category)
      @feature_count[feature][category] += 1
    end
    
    def increment_category(category)
      @category_count[category] += 1
    end
    
    ##
    # Returns the number of items in a given category
    def category_count(category)
      (@category_count[category] || 0).to_f
    end    

    ##
    # List all categories for this classifier.
    def categories
      @category_count.keys
    end

    ##
    # Returns the total number of items
    def total_count
      total = 0
      @category_count.values.each do |v|
        total += v
      end
      total
    end
  end
  
  ##
  # Like the other classifiers you construct one, passing in a block
  # to extract features, train it and ask questions. This class uses
  # Bayes' Theorem to calculate the probability of a particular
  # category for a given document:
  #   Pr(Category | Document) = Pr(Document | Category) * Pr(Category) / Pr(Document)
  #
  # This classifer is called "naive" because it assumes that the features of
  # a document are independent. This isn't strictly true, but can still provide
  # useful results nonetheless.
  # == Examples
  #   c = Filtering::NaiveBayes.new
  #
  #   c.train("Nobody owns the water", :good)
  #   c.train("the quick rabbit jumps fences", :good)
  #   c.train("buy pharmaceuticals now", :bad)
  #   c.train("make quick money at the online casino", :bad)
  #   c.train("the quick brown fox jumps", :good)
  #  
  #   c.prob("quick rabbit", :good)  #=> ~ 0.156
  #   c.prob("quick rabbit", :bad)   #=> ~ 0.050
  class NaiveBayes < Classifier
    ##
    # Returns the probability of the category, i.e. Pr(Document|Category)
    def prob(item, category)
      cat_prob = category_count(category) / total_count
      doc_prob = document_probability(item, category)
      doc_prob * cat_prob
    end

    ##
    # Determines the probability that a given document is
    # within a given category.
    private
    def document_probability(item, category)
      p = 1
      get_features(item).each do |f|
        p *= weighted_probability(f, category) do |f, c|
          self.feature_probability(f, c)
        end
      end
      p
    end
  end
  
  ##
  # Works like the other classifiers. Construct one, pass it a
  # block to extract features, train, and ask it questions.
  #
  # This classifer improves upon the +NaiveBayes+ by calculting the probability
  # of each feature, combines them and tests to see if the set is more or less
  # likely than a random set.
  # == Examples
  #   c = Filtering::Fisher.new
  #
  #   c.train("Nobody owns the water", :good)
  #   c.train("the quick rabbit jumps fences", :good)
  #   c.train("buy pharmaceuticals now", :bad)
  #   c.train("make quick money at the online casino", :bad)
  #   c.train("the quick brown fox jumps", :good)
  #
  #   c.fisher_prob("quick rabbit", :good)  #=> ~ 0.780
  #   c.fisher_prob("quick rabbit", :bad)   #=> ~ 0.356  
  class Fisher < Classifier

    ##
    # A +Hash+ for setting minimums for a particular category. This 
    # is used by the +classify+ method.
    attr_reader :minimums

    def initialize(&block)
      super(block)
      @minimums = {}
      @minimums.default = 0.0
    end

    ##
    # Classify the given +item+. How the text is classified is affected
    # by any minimums set for a particular category via the +minimums+
    # +Hash+ attribute. By default, the minimum for each category is set
    # to +0.0+.
    # == Parameters
    # * <tt>item</tt> The text block to classify
    # * <tt>default</tt> An optional category if one can't be determined.
    def classify(item, default=nil)
      best = default
      max = 0.0
      categories.each do |cat|
        p = fisher_prob(item, cat)
        if p > @minimums[cat] and p > max
          best = cat
          max = p
        end
      end
      best
    end

    ##
    # Returns the proportion of P(feature | category) relative to
    # sum of probabilities of _all_ categories for the given +feature+.
    # Like the other probability functions, this one assumes the classifier
    # has been trained with calls to the +train+ method.
    def prob(feature, category)
      fprob = feature_probability(feature, category)
      return 0 if fprob == 0
      
      freq_sum = 0
      categories.each { |cat| freq_sum += feature_probability(feature, cat) }
      fprob / freq_sum
    end
    
    ##
    # Multiplies the probabilities of each feature, applies
    # the natural log and multiplies by -2. Why? Beats the 
    # hell out of me.
    def fisher_prob(item, category)
      p = 1
      features = get_features(item).each do |f|
        p *= weighted_probability(f, category) do |f, c|
          self.prob(f, c)
        end
      end
      
      score = -2 * Math.log(p)
      inv_chi2(score, features.size * 2)
    end
    
    private
    ##
    # An mplementation of the inverse chi-square function
    # http://en.wikipedia.org/wiki/Inverse-chi-square_distribution
    def inv_chi2(chi, df)
      m = chi / 2.0
      sum = term = Math.exp(-m)
      (1...df/2).each do |i|
        term *= m / i
        sum += term
      end
      
      [sum, 1.0].min
    end
  end
end