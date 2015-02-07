#
# Connect directly to an ESX host and get performance manager metrics related to disk performance
# TODO: Add json output to feed this data to graphite.
# 
# References: (Get the 5.5 API docs if you want to look for changes. But these counters are a start.
# https://www.vmware.com/support/developer/vc-sdk/visdk400pubs/ReferenceGuide/disk_counters.html
# 
# 5.5 API reference
# https://pubs.vmware.com/vsphere-55/index.jsp#com.vmware.wssdk.apiref.doc/right-pane.html

require 'trollop'
require 'rbvmomi'

VIM = RbVmomi::VIM

#
# Random thoughts, but RVC is good so keeping them in....
#

# Some RVC commands
#  /conn.serviceContent.serviceManager.service[0].service.ExecuteSimpleCommand(:arguments => ["FetchStats"])
#  

#/conn.serviceContent.perfManager.perfCounter.each{ |c| if c.nameInfo.label == "Usage"; puts 'CRAP'; puts c.unitInfo.key; break; end}
#

#/conn.serviceContent.perfManager.perfCounter.each{ |c| if c.nameInfo.key == "deviceLatency"; puts "Property: #{c.nameInfo.key}: The Key is #{c.key}"; break; end}
opts = Trollop::options do
  opt :host, "ESX Server Hostname or IP", :type => :string
  opt :user, "Username", :type => :string
  opt :password, "Password", :type => :string
end

host = opts[:host]
user = opts[:user]
password = opts[:password]

#
# TODO: Generalize this to work with other metrics, not just latencies
#

perfProperties = [{:name => "deviceLatency", :id => nil, :values => []}, 
  {:name => "deviceReadLatency", :units => 'milliseconds', :id => nil, :values => []},
  {:name => "deviceWriteLatency", :units => 'milliseconds', :id => nil, :values => []}, 
  {:name => "kernelReadLatency", :units => 'milliseconds', :id => nil, :values => []},
  {:name => "kernelWriteLatency", :units => 'milliseconds', :id => nil, :values => []}, 
  {:name => "kernelLatency", :units => 'milliseconds', :id => nil, :values => []}, 
  {:name => "totalLatency", :units => 'milliseconds', :id => nil, :values => []}, 
  {:name => "commands", :units => 'SCSI commands/second', :id => nil, :values => []}, 
] 
  

# Disk latencies likely caused by array
#deviceLatencyId = nil
#deviceReadLatencyId = nil
#deviceWriteLatencyId = nil

# Kernel side latencies. Are the per LUN queue depths too small?
# Use ESXTOP to check commands curently queued on the LUN. Might need
# to increase queue depth. If you make the change, look for corresponding
# increase in writes/second. Otherwise, you may just be hitting IOPS limitations
# on the array.
#

#kernelReadLatencyId = nil
#kernelWriteLatencyId = nil
#kernelAverageLatencyId = nil
#totalLatencyId = nil

begin
  vim = RbVmomi::VIM.connect( :host => host, :user => user, 
  :password => password, :insecure => true )
  puts "#{Time.now}: INFO: Opened connection: #{vim}"
rescue Exception => ex
  puts "#{ex.message}"
  exit
end
puts vim

# Make a performance manager object
pm = vim.serviceContent.perfManager

# Get all the performance metrics first from the PerfManager
# TODO: Getting the queue length on the host. We want to know if the
# LUN queue on the host side is filling up from IOs being sent by the 
# VMs. Might have to do a separate script that parses esxtop output, and this 
# may have more overhead on the host than using the perfManager.
#


#
# Find matches in the performance manager properties for what we want to track.
#

vim.serviceContent.perfManager.perfCounter.each{ |property|
  perfProperties.each{ |entry|
    if property.nameInfo.key == entry[:name]
      entry[:id] = property.key
      #puts "DEBUG: Pushing metric ID: #{property.key}"
    end
  }
}

perfProperties.each { |entry|
    puts "Getting metrics for: #{entry}"
}


# Get a managed obj ref to just this host.
host = vim.serviceInstance.find_datacenter.hostFolder.children.first.host[0]


#
# Go through the performance metrics one at a time, modifying the query spec each time around
#

#
# Make a performance query spec
#

perfProperties.each { |entry|
  metrics = [] # {:timeStamp => int, :units => str, :metric => int, :device => str}
  metricId = entry[:id]

  #
  # This spec gets up to 20 of the last perf metrics, starting from the current
  # time on the host.
  #

  pqs = RbVmomi::VIM::PerfQuerySpec(
    entity: host,
    intervalId: 20,
    maxSample: 20,
    metricId: [{counterId: metricId, instance: '*'}],
  )

  # This is an array, but it only has a single (large) item of return data.
  result = pm.QueryPerf({querySpec: [pqs]})


  #result.each {|r| r.value.each {|s| puts "DEBUG #{s._get_property(:id)._get_property(:instance)}"}}

  # DEBUG: This gets the instance ID, which in the case of a disk is the path to the physical disk.
  #  I ended up using this later.
  #  TODO: Test with multiple disks attached to a host. I'm going to setup an NFS virtual 
  #  appliance and attach it to my local ESX test host, then deploy some VMs to the NFS share.
  #  I'm using Mike Brown's 'damn small linux' test appliance, it's only about 52MB.
  #

  # result.each {|r| r.value.each {|s| puts "DEBUG #{s.id.instance}"}}
  
  #
  # Annoying, but the timestamps and the associated latency values are stored in different
  # arrays. If you want to map them together it looks like you have to do it yourself.
  #

  result.each { |r|
    r.sampleInfo.each { |sample| 
      #puts "DEBUG: Sample Timestamp: #{sample.timestamp}" 
      metrics << {:timestamp => sample.timestamp, :metric => 123456789}
      #puts "DEBUG: SAMPLE: #{sample.props}"
    }
   
    #
    # r.value is of Type RbVmomi::VIM::PerfMetricIntSeries
    # You can call the value method and get yet another
    # array that contains all the latencies in milliseconds.
    #
    
    # Do the array mapping here, old skool style
    index = 0
    
    r.value.each { |s|
      s.value.each {|v| 
        metrics[index][:device] = s.id.instance

        # Push the value to the metrics array of hash objects
        metrics[index][:metric] = v
      
        # puts "DEBUG: New metric: #{metrics[index]}"
        index += 1    
      }
    }
  } 
  
  puts "################"
  puts "DATA: ID => #{metricId}; NAME => #{entry[:name]}: UNITS => #{entry[:units]}"
  metrics.each{ |time,metric| 
    puts "#{time}: #{metric}"
  }
}
  
vim.close()
exit

# More Random Notes:
#
# TODO: Provision some dummy VMs in the vitual esxi host to test IO
# Run an io tool in them. 
#
#
#DISK GAVG  25  Look at “DAVG” and “KAVG” as the sum of both is GAVG.
#DISK DAVG  25  Disk latency most likely to be caused by array.
#DISK KAVG  2 Disk latency caused by the VMkernel, 
#high KAVG usually means queuing. Check “QUED”.
#
