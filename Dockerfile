FROM ruby:2.1.2
MAINTAINER Richard Li <richard.li@sailpoint.com>

RUN mkdir /code

RUN gem install bundler

RUN touch /var/log/rally_time_calc.log

RUN touch /code/rally_time_calc.yml

COPY rally_time_calc.rb /code/rally_time_calc.rb
COPY Gemfile /code/Gemfile

WORKDIR /code

RUN bundle

CMD ruby rally_time_calc.rb >> /var/log/rally_time_calc.log
