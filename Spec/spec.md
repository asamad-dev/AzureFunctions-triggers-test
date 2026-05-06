Here is what we are going to do in this project:

Triger 1: Blob Trigger
1. We should have a stoage where when we upload a csv file it will trigger our azure function.
2. it will then save the file name and total number of rows of that csv in a table sql database.
3. Then azuze function will read it and extract the data from, it and then insert it into service bus queue.

Trigger 2: Queue Trigger 1
1. We will have another azure function that will be triggered by the service bus queue.
2. This function will read the data from the queue and then insert it into a sql database.
3. We will also have a logic to check if the data already exists in the database, if it does then we will update the existing record instead of inserting a new one. it will be based on file name and row count.
4. when all rows are processed, then it will send a tick in a new queue that will say all data is sent to database.

Trigger 3: Queue Trigger 2
1. the third trigger we will have another azure function that will be triggered by the new queue that we created in the previous step.
2. This function will read the tick from the queue and then it will read data from sql and put all data into a new csv file and save that file to a new blob storage which will act as archive for our data.
3. We will also have a logic to check if the file already exists in the archive blob storage, if it does then we will append the new data to the existing file instead of creating a new one.



Notes:
1. Connect blob and service bus via connection string.
2. see image.png to get more idea about the architecture of the project.


Azure:
1. resource of azure function using consumption plan (classic) on cloud
2. make a resource azure service (basic or standard) 
make a queue in it 
3. connect blob via connection string first but then connect service bus or blob not using connection string but via managed identity 